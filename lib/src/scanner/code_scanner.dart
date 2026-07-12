import 'dart:async';
import 'dart:typed_data';

import '../nitro_camera.native.dart' show CameraFrame;
import '../processing/frame_processor.dart';
import 'decoders/code11.dart';
import 'decoders/industrial_2of5.dart';
import 'decoders/msi.dart';
import 'decoders/pharmacode.dart';
import 'decoders/postnet.dart';
import 'decoders/rm4scc.dart';
import 'decoders/telepen.dart';
import 'decoders/zxing_decoder.dart';
import 'engine/bar_extractor.dart';
import 'engine/binarizer.dart';
import 'engine/scanline.dart';
import 'types.dart';

export 'types.dart';

/// Fraction of the frame's short side scanned by the streaming [CodeScanner]
/// — matches the centered viewfinder window in the UI. Cropping before
/// decoding is the main speed lever: the binarizer + readers touch ~half the
/// pixels, and the user aims the code inside the window anyway. The center
/// square is rotation- and cover-crop-invariant, so no orientation math is
/// needed to map the UI window into the frame.
const double kScannerWindowFraction = 0.72;

/// Decodes one frame's luma plane, looking only for [kind]'s formats.
///
/// Engine routing:
///  * zxing — common linear, 2D, GS1 DataBar (+GS1 flagging);
///  * built-in postal engine — POSTNET / PLANET / RM4SCC / KIX;
///  * built-in width engine — MSI, Code 11, Industrial 2-of-5, Telepen;
///  * built-in Pharmacode engine — one- & two-track (explicit kinds only).
///
/// Pure and synchronous — callable directly (e.g. from a custom isolate or a
/// one-shot still scan). The camera must be streaming **YUV** (`pixelFormat
/// 0`); BGRA bytes decode as noise. Returns `null` when nothing was found.
///
/// [windowCropFraction] < 1.0 scans only the centered square covering that
/// fraction of the frame's short side (zero-copy view — no pixels are moved).
CodeResult? decodeCodeFrame(
  FrameData f,
  CodeScanKind kind, {
  double windowCropFraction = 1.0,
}) {
  final win = _windowOf(f, windowCropFraction);
  final factor = win.side > 700 ? 2 : 1;
  final hit = _decodePass(f, win, factor, kind.formats, tryUpright: true, tryRotated: true);
  return _toResult(hit, f);
}

/// A hit with the geometry needed to map points back to window space.
class _RawHit {
  final RawDecode raw;
  final bool rotated;

  /// Decoded-bitmap dims BEFORE rotation (the upright decimated window).
  final int w, h;

  /// Decimation factor the hit was found at.
  final int factor;
  const _RawHit(this.raw, this.rotated, this.w, this.h, this.factor);
}

class _Window {
  final int left, top, side;
  const _Window(this.left, this.top, this.side);
}

_Window _windowOf(FrameData f, double fraction) {
  if (fraction >= 1.0) {
    final side = f.width < f.height ? f.width : f.height;
    return _Window((f.width - side) ~/ 2, (f.height - side) ~/ 2, side);
  }
  final side = ((f.width < f.height ? f.width : f.height) * fraction).round();
  return _Window((f.width - side) ~/ 2, (f.height - side) ~/ 2, side);
}

/// Maps a [_RawHit]'s points to window-normalized coordinates and builds the
/// [CodeResult].
CodeResult? _toResult(_RawHit? hit, FrameData f) {
  if (hit == null) return null;
  final raw = hit.raw;
  List<double>? norm;
  final pts = raw.points;
  if (pts != null && pts.length >= 2) {
    norm = mapDecodedPointsToWindow(
      pts,
      hit.w,
      hit.h,
      hit.rotated,
      frameOrientation: f.orientation,
      mirrored: f.isMirrored,
    );
  }
  return CodeResult(
    raw.text,
    raw.format,
    timestamp: f.timestamp,
    isGs1: raw.isGs1,
    windowPoints: norm,
  );
}

/// Maps points from decoded-bitmap pixel space back to the scan window's
/// normalized (0..1) space **as displayed** — ready to paint over the on-screen
/// viewfinder.
///
/// [w]×[h] are the sensor-oriented decimated window dims; when [rotated],
/// points are in the 90°-clockwise-rotated bitmap (h×w). The camera buffer is
/// sensor-oriented while the preview shows it rotated upright (and mirrored
/// for the front camera), so [frameOrientation] (the frame's
/// clockwise-degrees-to-upright) and [mirrored] are applied last. The window
/// is a centered square, so it maps onto itself under these transforms.
List<double> mapDecodedPointsToWindow(
  List<double> points,
  int w,
  int h,
  bool rotated, {
  int frameOrientation = 0,
  bool mirrored = false,
}) {
  final out = <double>[];
  for (var i = 0; i + 1 < points.length; i += 2) {
    final px = points[i], py = points[i + 1];
    double x, y;
    if (rotated) {
      // rotate90cw mapped (x,y) → (h-1-y, x); invert: x = py, y = h-1-px.
      x = py;
      y = h - 1 - px;
    } else {
      x = px;
      y = py;
    }
    var nx = (x / w).clamp(0.0, 1.0);
    var ny = (y / h).clamp(0.0, 1.0);
    switch (frameOrientation) {
      case 90: // rotate cw: (x, y) → (1-y, x)
        final t = nx;
        nx = 1.0 - ny;
        ny = t;
      case 180:
        nx = 1.0 - nx;
        ny = 1.0 - ny;
      case 270: // rotate ccw: (x, y) → (y, 1-x)
        final t = nx;
        nx = ny;
        ny = 1.0 - t;
    }
    if (mirrored) nx = 1.0 - nx;
    out.add(nx);
    out.add(ny);
  }
  return out;
}

/// One decode attempt over the window at 1/[factor] scale, optionally trying
/// the upright and/or 90°-rotated orientation. [formats] applies to the
/// upright pass; the rotated pass drops 2D formats (rotation-invariant).
_RawHit? _decodePass(
  FrameData f,
  _Window win,
  int factor,
  Set<CodeFormat> formats, {
  required bool tryUpright,
  required bool tryRotated,
}) {
  final srcStride = f.effectiveBytesPerRow;
  Uint8List bytes;
  int stride, left, top, w, h;
  if (factor > 1) {
    w = win.side ~/ factor;
    h = win.side ~/ factor;
    final dec = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final src = (win.top + y * factor) * srcStride + win.left;
      final dst = y * w;
      for (var x = 0; x < w; x++) {
        dec[dst + x] = f.bytes[src + x * factor];
      }
    }
    bytes = dec;
    stride = w;
    left = 0;
    top = 0;
  } else {
    bytes = f.bytes;
    stride = srcStride;
    left = win.left;
    top = win.top;
    w = win.side;
    h = win.side;
  }

  if (tryUpright) {
    final raw = _decodeWindow(bytes, stride, left, top, w, h, formats);
    if (raw != null) return _RawHit(raw, false, w, h, factor);
  }

  if (tryRotated) {
    final rotatable = formats.where((x) => !x.is2D).toSet();
    if (rotatable.isNotEmpty) {
      final rot = Uint8List(w * h);
      // rotate 90° clockwise: (x, y) → (h-1-y, x)
      for (var y = 0; y < h; y++) {
        final src = (top + y) * stride + left;
        final dstX = h - 1 - y;
        for (var x = 0; x < w; x++) {
          rot[x * h + dstX] = bytes[src + x];
        }
      }
      final raw = _decodeWindow(rot, h, 0, 0, h, w, rotatable);
      if (raw != null) return _RawHit(raw, true, w, h, factor);
    }
  }
  return null;
}

// ── Adaptive streaming scan (worker-isolate state) ──────────────────────────
//
// These globals live in the scanner's WORKER isolate, so they persist across
// frames: a last-hit cache (replay the exact level/orientation/format that
// just worked — steady-state hits cost one cheap decode) and an escalation
// ladder (cheap small pass every frame; bigger pass only every 3rd miss).
CodeFormat? _lastFormat;
bool _lastRotated = false;
int _lastFactor = 1;
int _lastMisses = 0;
int _frameIdx = 0;

/// Streaming decode with the adaptive ladder + last-hit cache. Used by the
/// [CodeScanner] worker handlers; call [decodeCodeFrame] for stateless
/// one-shot decodes.
CodeResult? scanFrameAdaptive(FrameData f, CodeScanKind kind) {
  final win = _windowOf(f, kScannerWindowFraction);
  _frameIdx++;

  // Ladder levels: A ≈ ≤300 px (fast), B ≈ 2× A (thorough).
  var fA = (win.side / 300).ceil();
  if (fA < 1) fA = 1;
  final fB = fA > 1 ? fA ~/ 2 : 1;

  // 0. Last-hit replay: exact level + orientation + format of the previous
  // success.
  final lastFormat = _lastFormat;
  if (lastFormat != null && kind.formats.contains(lastFormat)) {
    final hit = _decodePass(f, win, _lastFactor, {lastFormat}, tryUpright: !_lastRotated, tryRotated: _lastRotated);
    if (hit != null) {
      _lastMisses = 0;
      return _toResult(hit, f);
    }
    if (++_lastMisses > 5) _lastFormat = null;
  }

  // 1. Fast level.
  var hit = _decodePass(f, win, fA, kind.formats, tryUpright: true, tryRotated: true);

  // 2. Thorough level, every 2nd miss, BOTH orientations — small 1D codes
  // that level A can't resolve are often only readable rotated (portrait
  // phone), so B must retry rotation too.
  if (hit == null && fB < fA && _frameIdx % 2 == 0) {
    hit = _decodePass(f, win, fB, kind.formats, tryUpright: true, tryRotated: true);
  }

  if (hit != null) {
    _lastFormat = hit.raw.format;
    _lastRotated = hit.rotated;
    _lastFactor = hit.factor;
    _lastMisses = 0;
  }
  return _toResult(hit, f);
}

/// Runs the full engine cascade over one window orientation.
RawDecode? _decodeWindow(
  Uint8List bytes,
  int stride,
  int left,
  int top,
  int w,
  int h,
  Set<CodeFormat> formats,
) {
  RawDecode? raw;

  // 1. zxing engine (linear + 2D + DataBar).
  if (formats.any((x) => x.isZxing)) {
    raw = zxingDecode(
      bytes,
      stride: stride,
      left: left,
      top: top,
      width: w,
      height: h,
      formats: formats,
    );
  }

  // The built-in engines share one binarized window.
  GrayWindow? win;
  GrayWindow window() => win ??= GrayWindow(
    bytes,
    stride: stride,
    left: left,
    top: top,
    width: w,
    height: h,
  );

  // 2. Postal engine (height-modulated).
  if (raw == null && formats.any((x) => x.isPostal)) {
    final bars = extractBars(window());
    if (bars != null) {
      final states = classify4State(bars);
      if (formats.contains(CodeFormat.rm4scc)) {
        raw = decodeRm4scc(states);
      }
      if (raw == null && (formats.contains(CodeFormat.postnet) || formats.contains(CodeFormat.planet))) {
        raw = decodePostnetPlanet(classify2State(bars));
      }
      if (raw == null && formats.contains(CodeFormat.kix)) {
        raw = decodeKix(states);
      }
    }
  }

  // 3. Width engine (MSI / Code 11 / Industrial 2-of-5 / Telepen /
  //    Pharmacode one-track).
  final wantsWidth = formats.contains(CodeFormat.msi) || formats.contains(CodeFormat.code11) || formats.contains(CodeFormat.industrial2of5) || formats.contains(CodeFormat.telepen) || formats.contains(CodeFormat.pharmacode);
  if (raw == null && wantsWidth) {
    for (final runs in extractScanlineRuns(window())) {
      final units = runsToUnits(runs);
      if (units == null) continue;
      raw ??= formats.contains(CodeFormat.msi) ? decodeMsi(units) : null;
      raw ??= formats.contains(CodeFormat.code11) ? decodeCode11(units) : null;
      raw ??= formats.contains(CodeFormat.industrial2of5) ? decodeIndustrial2of5(units) : null;
      raw ??= formats.contains(CodeFormat.telepen) ? decodeTelepen(units) : null;
      raw ??= formats.contains(CodeFormat.pharmacode) ? decodePharmaOneTrack(units) : null;
      if (raw != null) break;
    }
  }

  // 4. Pharmacode two-track (height-modulated, explicit only).
  if (raw == null && formats.contains(CodeFormat.pharmacodeTwoTrack)) {
    final bars = extractBars(window(), minBars: 3);
    if (bars != null) {
      raw = decodePharmaTwoTrack(classify4State(bars));
    }
  }

  return raw;
}

// Isolate handlers must be top-level; one per kind carries the selection
// across the isolate boundary without extra plumbing. Streaming scans use the
// adaptive ladder + last-hit cache over the viewfinder window.
CodeResult? _scanQr(FrameData f) => scanFrameAdaptive(f, CodeScanKind.qr);
CodeResult? _scan1D(FrameData f) => scanFrameAdaptive(f, CodeScanKind.oneD);
CodeResult? _scan2D(FrameData f) => scanFrameAdaptive(f, CodeScanKind.twoD);
CodeResult? _scanPostal(FrameData f) => scanFrameAdaptive(f, CodeScanKind.postal);
CodeResult? _scanPharma(FrameData f) => scanFrameAdaptive(f, CodeScanKind.pharma);
CodeResult? _scanAll(FrameData f) => scanFrameAdaptive(f, CodeScanKind.all);

FrameHandler<CodeResult?> _handlerFor(CodeScanKind kind) => switch (kind) {
  CodeScanKind.qr => _scanQr,
  CodeScanKind.oneD => _scan1D,
  CodeScanKind.twoD => _scan2D,
  CodeScanKind.postal => _scanPostal,
  CodeScanKind.pharma => _scanPharma,
  CodeScanKind.all => _scanAll,
};

/// Confirms detections across consecutive frames and de-duplicates emissions
/// — pure logic, unit-testable without a camera.
///
/// A payload is CONFIRMED once it decodes on [confirmationFrames] consecutive
/// successful frames (misreads virtually never repeat identically). Confirmed
/// payloads then respect a per-payload [cooldown] so a code held in view
/// doesn't spam results.
class ScanConfirmer {
  final int confirmationFrames;
  final Duration cooldown;

  String? _pendingText;
  int _pendingCount = 0;
  final Map<String, int> _lastEmitMs = {};

  ScanConfirmer({
    this.confirmationFrames = 2,
    this.cooldown = const Duration(milliseconds: 1500),
  });

  /// Feed one frame's outcome; returns the result when it just got confirmed
  /// (and is off cooldown), else null. [nowMs] is injectable for tests.
  CodeResult? onFrame(CodeResult? r, {int? nowMs}) {
    if (r == null) {
      // Confirmation requires CONSECUTIVE hits.
      _pendingText = null;
      _pendingCount = 0;
      return null;
    }
    if (r.text == _pendingText) {
      _pendingCount++;
    } else {
      _pendingText = r.text;
      _pendingCount = 1;
    }
    if (_pendingCount < confirmationFrames) return null;

    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final last = _lastEmitMs[r.text];
    if (last != null && now - last < cooldown.inMilliseconds) return null;
    _lastEmitMs[r.text] = now;
    return r;
  }

  void reset() {
    _pendingText = null;
    _pendingCount = 0;
    _lastEmitMs.clear();
  }
}

/// Scans camera frames for barcodes / QR codes of a selectable [kind].
///
/// Runs decoding on a persistent worker isolate with drop-latest backpressure
/// (via [CameraFrameProcessor]), so scanning never stalls the preview. Uses
/// the adaptive resolution ladder + last-hit cache internally.
///
/// ```dart
/// final scanner = CodeScanner(kind: CodeScanKind.qr);
/// await scanner.start(controller.frames);
/// scanner.results.listen((code) => print(code));       // confirmed
/// scanner.detections.listen((d) => highlight(d));      // every raw hit
/// ```
class CodeScanner {
  /// Which code family to look for. Fixed per instance — create a new scanner
  /// to change it (the worker isolate restarts either way).
  final CodeScanKind kind;

  /// Continuous (default) or one-shot delivery — see [ScanMode].
  final ScanMode mode;

  final ScanConfirmer _confirmer;
  final CameraFrameProcessor<CodeResult?> _proc;
  final StreamController<CodeResult> _confirmed = StreamController<CodeResult>.broadcast();
  StreamSubscription<CameraFrame>? _sub;
  StreamSubscription<CodeResult?>? _rawSub;
  bool _started = false;
  bool _armed = true;

  CodeScanner({
    this.kind = CodeScanKind.all,
    this.mode = ScanMode.continuous,
    int confirmationFrames = 2,
    Duration cooldown = const Duration(milliseconds: 1500),
  }) : _confirmer = ScanConfirmer(
         confirmationFrames: confirmationFrames,
         cooldown: cooldown,
       ),
       _proc = CameraFrameProcessor<CodeResult?>(_handlerFor(kind));

  /// CONFIRMED results: same payload on N consecutive frames, deduplicated by
  /// the cooldown. In [ScanMode.oneShot], at most one until [resume].
  Stream<CodeResult> get results => _confirmed.stream;

  /// Every raw per-frame detection (unconfirmed) — drive live highlights
  /// with this; act on [results].
  Stream<CodeResult> get detections => _proc.results.where((r) => r != null).cast<CodeResult>();

  /// Per-frame decode timing — emitted for EVERY analysed frame (hit or
  /// miss). Feed to a benchmarking HUD: `stats.elapsedMillis` is how long the
  /// full engine pass took on the worker isolate.
  Stream<FrameProcessStats> get stats => _proc.stats;

  /// Whether a one-shot scanner is still waiting for its result.
  bool get isArmed => _armed;

  /// Re-arms a [ScanMode.oneShot] scanner for the next scan.
  void resume() {
    _confirmer.reset();
    _armed = true;
  }

  /// Spawns the worker and starts consuming [frames].
  Future<void> start(Stream<CameraFrame> frames) async {
    if (_started) return;
    _started = true;
    await _proc.start();
    _rawSub = _proc.results.listen((r) {
      if (!_armed) return;
      final confirmed = _confirmer.onFrame(r);
      if (confirmed == null) return;
      if (mode == ScanMode.oneShot) _armed = false;
      if (!_confirmed.isClosed) _confirmed.add(confirmed);
    });
    _sub = _proc.attach(frames);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _rawSub?.cancel();
    await _proc.dispose();
    if (!_confirmed.isClosed) await _confirmed.close();
  }
}
