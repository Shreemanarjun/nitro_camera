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
  int left, top, w, h;
  if (windowCropFraction < 1.0) {
    final side =
        ((f.width < f.height ? f.width : f.height) * windowCropFraction)
            .round();
    left = (f.width - side) ~/ 2;
    top = (f.height - side) ~/ 2;
    w = side;
    h = side;
  } else {
    left = 0;
    top = 0;
    w = f.width;
    h = f.height;
  }
  var stride = f.effectiveBytesPerRow;
  var bytes = f.bytes;

  // Decimate large windows 2× before decoding: barcode readers don't need
  // >~700 px — quartering the pixels roughly quarters binarize+decode time
  // (measured ~180 ms → ~50 ms for the full ALL cascade on a 1036² window).
  if (w > 700 && h > 700) {
    final dw = w ~/ 2, dh = h ~/ 2;
    final dec = Uint8List(dw * dh);
    for (var y = 0; y < dh; y++) {
      final src = (top + y * 2) * stride + left;
      final dst = y * dw;
      for (var x = 0; x < dw; x++) {
        dec[dst + x] = bytes[src + x * 2];
      }
    }
    bytes = dec;
    stride = dw;
    left = 0;
    top = 0;
    w = dw;
    h = dh;
  }
  final formats = kind.formats;

  // Pass 1: the window as delivered (sensor orientation — landscape rows).
  var raw = _decodeWindow(bytes, stride, left, top, w, h, formats);

  // Pass 2: linear/postal/pharma symbologies are read along rows, so a
  // barcode held horizontally ON SCREEN lies vertically in the sensor buffer
  // when the device is portrait — rotate the window 90° and retry those
  // formats. (2D codes are rotation-invariant; skip them on this pass.)
  if (raw == null) {
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
      raw = _decodeWindow(rot, h, 0, 0, h, w, rotatable);
    }
  }

  if (raw == null) return null;
  return CodeResult(
    raw.text,
    raw.format,
    timestamp: f.timestamp,
    isGs1: raw.isGs1,
  );
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
      if (raw == null &&
          (formats.contains(CodeFormat.postnet) ||
              formats.contains(CodeFormat.planet))) {
        raw = decodePostnetPlanet(classify2State(bars));
      }
      if (raw == null && formats.contains(CodeFormat.kix)) {
        raw = decodeKix(states);
      }
    }
  }

  // 3. Width engine (MSI / Code 11 / Industrial 2-of-5 / Telepen /
  //    Pharmacode one-track).
  final wantsWidth = formats.contains(CodeFormat.msi) ||
      formats.contains(CodeFormat.code11) ||
      formats.contains(CodeFormat.industrial2of5) ||
      formats.contains(CodeFormat.telepen) ||
      formats.contains(CodeFormat.pharmacode);
  if (raw == null && wantsWidth) {
    for (final runs in extractScanlineRuns(window())) {
      final units = runsToUnits(runs);
      if (units == null) continue;
      raw ??= formats.contains(CodeFormat.msi) ? decodeMsi(units) : null;
      raw ??=
          formats.contains(CodeFormat.code11) ? decodeCode11(units) : null;
      raw ??= formats.contains(CodeFormat.industrial2of5)
          ? decodeIndustrial2of5(units)
          : null;
      raw ??=
          formats.contains(CodeFormat.telepen) ? decodeTelepen(units) : null;
      raw ??= formats.contains(CodeFormat.pharmacode)
          ? decodePharmaOneTrack(units)
          : null;
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
// across the isolate boundary without extra plumbing. Streaming scans crop to
// the viewfinder window (kScannerWindowFraction) for speed.
CodeResult? _scanQr(FrameData f) => decodeCodeFrame(f, CodeScanKind.qr,
    windowCropFraction: kScannerWindowFraction);
CodeResult? _scan1D(FrameData f) => decodeCodeFrame(f, CodeScanKind.oneD,
    windowCropFraction: kScannerWindowFraction);
CodeResult? _scan2D(FrameData f) => decodeCodeFrame(f, CodeScanKind.twoD,
    windowCropFraction: kScannerWindowFraction);
CodeResult? _scanPostal(FrameData f) => decodeCodeFrame(f, CodeScanKind.postal,
    windowCropFraction: kScannerWindowFraction);
CodeResult? _scanPharma(FrameData f) => decodeCodeFrame(f, CodeScanKind.pharma,
    windowCropFraction: kScannerWindowFraction);
CodeResult? _scanAll(FrameData f) => decodeCodeFrame(f, CodeScanKind.all,
    windowCropFraction: kScannerWindowFraction);

FrameHandler<CodeResult?> _handlerFor(CodeScanKind kind) => switch (kind) {
      CodeScanKind.qr => _scanQr,
      CodeScanKind.oneD => _scan1D,
      CodeScanKind.twoD => _scan2D,
      CodeScanKind.postal => _scanPostal,
      CodeScanKind.pharma => _scanPharma,
      CodeScanKind.all => _scanAll,
    };

/// Scans camera frames for barcodes / QR codes of a selectable [kind].
///
/// Runs decoding on a persistent worker isolate with drop-latest backpressure
/// (via [CameraFrameProcessor]), so scanning never stalls the preview.
///
/// ```dart
/// final scanner = CodeScanner(kind: CodeScanKind.qr);
/// await scanner.start(controller.frames);
/// scanner.results.listen((code) => print(code));
/// ```
class CodeScanner {
  /// Which code family to look for. Fixed per instance — create a new scanner
  /// to change it (the worker isolate restarts either way).
  final CodeScanKind kind;

  final CameraFrameProcessor<CodeResult?> _proc;
  StreamSubscription<CameraFrame>? _sub;
  bool _started = false;

  CodeScanner({this.kind = CodeScanKind.all})
      : _proc = CameraFrameProcessor<CodeResult?>(_handlerFor(kind));

  /// Successful detections only.
  Stream<CodeResult> get results =>
      _proc.results.where((r) => r != null).cast<CodeResult>();

  /// Per-frame decode timing — emitted for EVERY analysed frame (hit or
  /// miss). Feed to a benchmarking HUD: `stats.elapsedMillis` is how long the
  /// full engine pass took on the worker isolate.
  Stream<FrameProcessStats> get stats => _proc.stats;

  /// Spawns the worker and starts consuming [frames].
  Future<void> start(Stream<CameraFrame> frames) async {
    if (_started) return;
    _started = true;
    await _proc.start();
    _sub = _proc.attach(frames);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _proc.dispose();
  }
}
