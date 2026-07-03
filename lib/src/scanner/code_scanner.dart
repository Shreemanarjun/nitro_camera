import 'dart:async';
import 'dart:typed_data';

import 'package:zxing_lib/common.dart' as zxing;
import 'package:zxing_lib/zxing.dart' as zxing;

import '../nitro_camera.native.dart' show CameraFrame;
import '../processing/frame_processor.dart';

/// Barcode / code symbologies the scanner can detect.
///
/// Coverage: all common **linear** codes (EAN/UPC incl. ISBN Bookland,
/// Code 39/93/128, ITF, Codabar), **GS1 DataBar** ([rss14] = GS1 DataBar,
/// [rssExpanded] = GS1 DataBar Expanded), and **2D** codes (QR, Data Matrix,
/// Aztec, PDF417, MaxiCode) including their **GS1 variants** (GS1-128,
/// GS1 DataMatrix, GS1 QR — flagged via [CodeResult.isGs1]). Postal
/// symbologies (POSTNET / RM4SCC / Intelligent Mail) are not decodable by the
/// underlying zxing engine; they need a dedicated native decoder.
///
/// The public API is deliberately decoupled from the underlying decoder
/// (currently `zxing_lib` in Dart) so a native (C++) implementation can be
/// swapped in without breaking callers.
enum CodeFormat {
  // ── 2D ──
  qrCode,
  dataMatrix,
  aztec,
  pdf417,
  maxicode,
  // ── 1D ──
  ean13,
  ean8,
  upcA,
  upcE,
  code39,
  code93,
  code128,
  itf,
  codabar,

  /// GS1 DataBar (formerly RSS-14).
  rss14,

  /// GS1 DataBar Expanded (formerly RSS Expanded).
  rssExpanded;

  /// Whether this is a 2D (matrix) symbology.
  bool get is2D => switch (this) {
        qrCode || dataMatrix || aztec || pdf417 || maxicode => true,
        _ => false,
      };

  /// Whether this is a 1D (linear) symbology.
  bool get is1D => !is2D;
}

/// Which family of codes to look for in a frame.
enum CodeScanKind {
  /// QR codes only — the fastest option.
  qr,

  /// Linear barcodes (EAN/UPC/Code-39/93/128/ITF/Codabar/RSS).
  oneD,

  /// Matrix codes (QR, Data Matrix, Aztec, PDF417, MaxiCode).
  twoD,

  /// Everything — 1D and 2D.
  all;

  /// The formats this kind scans for.
  Set<CodeFormat> get formats => switch (this) {
        qr => const {CodeFormat.qrCode},
        oneD => CodeFormat.values.where((f) => f.is1D).toSet(),
        twoD => CodeFormat.values.where((f) => f.is2D).toSet(),
        all => CodeFormat.values.toSet(),
      };

  String get label => switch (this) {
        qr => 'QR',
        oneD => '1D',
        twoD => '2D',
        all => 'ALL',
      };
}

/// A decoded code.
class CodeResult {
  final String text;
  final CodeFormat format;

  /// Frame timestamp (ms) the code was decoded from, when known.
  final int timestamp;

  /// Whether the symbol carries GS1-structured data: GS1 DataBar (always),
  /// GS1-128 / GS1 DataMatrix / GS1 QR (detected from the symbology
  /// identifier, e.g. `]C1`, `]d2`, `]Q3`, `]e0`).
  final bool isGs1;

  const CodeResult(
    this.text,
    this.format, {
    this.timestamp = 0,
    this.isGs1 = false,
  });

  /// The ISBN when this is a Bookland EAN-13 (978/979 prefix), else null.
  String? get isbn {
    if (format != CodeFormat.ean13) return null;
    if (!(text.startsWith('978') || text.startsWith('979'))) return null;
    return text;
  }

  @override
  String toString() => '${format.name}${isGs1 ? '·GS1' : ''}: $text';
}

// ── zxing mapping (internal) ────────────────────────────────────────────────

zxing.BarcodeFormat _toZxing(CodeFormat f) => switch (f) {
      CodeFormat.qrCode => zxing.BarcodeFormat.qrCode,
      CodeFormat.dataMatrix => zxing.BarcodeFormat.dataMatrix,
      CodeFormat.aztec => zxing.BarcodeFormat.aztec,
      CodeFormat.pdf417 => zxing.BarcodeFormat.pdf417,
      CodeFormat.maxicode => zxing.BarcodeFormat.maxicode,
      CodeFormat.ean13 => zxing.BarcodeFormat.ean13,
      CodeFormat.ean8 => zxing.BarcodeFormat.ean8,
      CodeFormat.upcA => zxing.BarcodeFormat.upcA,
      CodeFormat.upcE => zxing.BarcodeFormat.upcE,
      CodeFormat.code39 => zxing.BarcodeFormat.code39,
      CodeFormat.code93 => zxing.BarcodeFormat.code93,
      CodeFormat.code128 => zxing.BarcodeFormat.code128,
      CodeFormat.itf => zxing.BarcodeFormat.itf,
      CodeFormat.codabar => zxing.BarcodeFormat.codabar,
      CodeFormat.rss14 => zxing.BarcodeFormat.rss14,
      CodeFormat.rssExpanded => zxing.BarcodeFormat.rssExpanded,
    };

CodeFormat? _fromZxing(zxing.BarcodeFormat f) {
  for (final v in CodeFormat.values) {
    if (_toZxing(v) == f) return v;
  }
  return null;
}

/// Symbology identifiers that mark GS1-structured payloads.
const _gs1SymbologyIds = {']C1', ']e0', ']e1', ']e2', ']d2', ']Q3'};

/// Fraction of the frame's short side scanned by the streaming [CodeScanner]
/// — matches the centered viewfinder window in the UI. Cropping before
/// decoding is the main speed lever: the binarizer + readers touch ~half the
/// pixels, and the user aims the code inside the window anyway. The center
/// square is rotation- and cover-crop-invariant, so no orientation math is
/// needed to map the UI window into the frame.
const double kScannerWindowFraction = 0.72;

/// Decodes one frame's luma plane, looking only for [kind]'s formats.
///
/// Pure and synchronous — callable directly (e.g. from a custom isolate or a
/// one-shot still scan). The camera must be streaming **YUV** (`pixelFormat 0`);
/// BGRA bytes decode as noise. Returns `null` when nothing was found.
///
/// [windowCropFraction] < 1.0 scans only the centered square covering that
/// fraction of the frame's short side (zero-copy view — no pixels are moved).
CodeResult? decodeCodeFrame(
  FrameData f,
  CodeScanKind kind, {
  double windowCropFraction = 1.0,
}) {
  try {
    final zxing.LuminanceSource source;
    if (windowCropFraction < 1.0) {
      final side =
          ((f.width < f.height ? f.width : f.height) * windowCropFraction)
              .round();
      final left = (f.width - side) ~/ 2;
      final top = (f.height - side) ~/ 2;
      source = _StridedLuminanceSource(
        f.bytes,
        side,
        side,
        f.effectiveBytesPerRow,
        left: left,
        top: top,
      );
    } else {
      source = _StridedLuminanceSource(
        f.bytes,
        f.width,
        f.height,
        f.effectiveBytesPerRow,
      );
    }
    final bitmap = zxing.BinaryBitmap(zxing.HybridBinarizer(source));
    final result = zxing.MultiFormatReader().decode(
      bitmap,
      zxing.DecodeHint(
        possibleFormats: kind.formats.map(_toZxing).toList(),
        // Screens/print in poor light are often inverted-friendly.
        alsoInverted: true,
      ),
    );
    final format = _fromZxing(result.barcodeFormat);
    if (format == null) return null;
    final symbologyId = result
        .resultMetadata?[zxing.ResultMetadataType.symbologyIdentifier]
        ?.toString();
    final isGs1 = format == CodeFormat.rss14 ||
        format == CodeFormat.rssExpanded ||
        (symbologyId != null && _gs1SymbologyIds.contains(symbologyId));
    return CodeResult(
      result.text,
      format,
      timestamp: f.timestamp,
      isGs1: isGs1,
    );
  } catch (_) {
    return null; // MultiFormatReader throws NotFoundException on no match.
  }
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
CodeResult? _scanAll(FrameData f) => decodeCodeFrame(f, CodeScanKind.all,
    windowCropFraction: kScannerWindowFraction);

FrameHandler<CodeResult?> _handlerFor(CodeScanKind kind) => switch (kind) {
      CodeScanKind.qr => _scanQr,
      CodeScanKind.oneD => _scan1D,
      CodeScanKind.twoD => _scan2D,
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

/// [zxing.LuminanceSource] that reads a luma plane with an arbitrary **row
/// stride** (the camera's `bytesPerRow`) and an optional **window offset**
/// ([left], [top]) — a zero-copy cropped view over the full plane.
class _StridedLuminanceSource extends zxing.LuminanceSource {
  final Uint8List _pixels;
  final int _stride;
  final int _left;
  final int _top;

  _StridedLuminanceSource(
    this._pixels,
    int width,
    int height,
    this._stride, {
    int left = 0,
    int top = 0,
  })  : _left = left,
        _top = top,
        super(width, height);

  @override
  Uint8List getRow(int y, Uint8List? row) {
    final res = (row != null && row.length >= width) ? row : Uint8List(width);
    final start = (y + _top) * _stride + _left;
    final end = start + width;
    if (end <= _pixels.length) {
      res.setRange(0, width, _pixels, start);
    }
    return res;
  }

  @override
  Uint8List get matrix {
    if (_stride == width && _left == 0 && _top == 0) return _pixels;
    final m = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      final src = (y + _top) * _stride + _left;
      if (src + width > _pixels.length) break;
      m.setRange(y * width, y * width + width, _pixels, src);
    }
    return m;
  }

  @override
  bool get isCropSupported => false;
}
