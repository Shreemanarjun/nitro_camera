import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_zxing/nitro_zxing.dart';

/// [CodeScanner] handlers backed by zxing-cpp (`nitro_zxing`) instead of the
/// plugin's pure-Dart zxing port: native decode, no Dart allocation per frame.
/// Formats zxing-cpp doesn't read (MSI, Code 11, Industrial 2/5, Telepen,
/// postal, pharmacode) still go through the built-in Dart engines, so every
/// scan kind finds exactly what it did before.
///
/// Handlers run on the scanner's worker isolate, so they're top-level.
FrameHandler<CodeResult?> zxingCppHandlerFor(CodeScanKind kind) =>
    switch (kind) {
      CodeScanKind.qr => _qr,
      CodeScanKind.oneD => _oneD,
      CodeScanKind.twoD => _twoD,
      CodeScanKind.postal => _postal,
      CodeScanKind.pharma => _pharma,
      CodeScanKind.all => _all,
    };

CodeResult? _qr(FrameData f) => _scan(f, CodeScanKind.qr);
CodeResult? _oneD(FrameData f) => _scan(f, CodeScanKind.oneD);
CodeResult? _twoD(FrameData f) => _scan(f, CodeScanKind.twoD);
CodeResult? _postal(FrameData f) => _scan(f, CodeScanKind.postal);
CodeResult? _pharma(FrameData f) => _scan(f, CodeScanKind.pharma);
CodeResult? _all(FrameData f) => _scan(f, CodeScanKind.all);

const _toCpp = {
  CodeFormat.qrCode: ZxingFormat.qrCode,
  CodeFormat.dataMatrix: ZxingFormat.dataMatrix,
  CodeFormat.aztec: ZxingFormat.aztec,
  CodeFormat.pdf417: ZxingFormat.pdf417,
  CodeFormat.maxicode: ZxingFormat.maxiCode,
  CodeFormat.ean13: ZxingFormat.ean13,
  CodeFormat.ean8: ZxingFormat.ean8,
  CodeFormat.upcA: ZxingFormat.upcA,
  CodeFormat.upcE: ZxingFormat.upcE,
  CodeFormat.code39: ZxingFormat.code39,
  CodeFormat.code93: ZxingFormat.code93,
  CodeFormat.code128: ZxingFormat.code128,
  CodeFormat.itf: ZxingFormat.itf,
  CodeFormat.codabar: ZxingFormat.codabar,
  CodeFormat.rss14: ZxingFormat.dataBar,
  CodeFormat.rssExpanded: ZxingFormat.dataBarExpanded,
};
final _fromCpp = {for (final e in _toCpp.entries) e.value: e.key};

const _gs1Ids = {']C1', ']e0', ']e1', ']e2', ']d2', ']Q3'};

// Per-kind format splits, computed once per worker.
final _cppFormats = <CodeScanKind, Set<ZxingFormat>>{};
final _dartFormats = <CodeScanKind, Set<CodeFormat>>{};

CodeResult? _scan(FrameData f, CodeScanKind kind) {
  final cpp = _cppFormats[kind] ??= {for (final c in kind.formats) ?_toCpp[c]};
  final dart = _dartFormats[kind] ??= kind.formats
      .where((c) => !_toCpp.containsKey(c))
      .toSet();

  if (cpp.isNotEmpty) {
    final win = scannerWindowOf(f);
    final r = NitroZxing.instance.decode(
      f.bytes,
      width: f.width,
      height: f.height,
      rowStride: f.effectiveBytesPerRow,
      formats: cpp,
      live: true,
      region: (left: win.left, top: win.top, width: win.side, height: win.side),
    );
    if (r != null) {
      final format = _fromCpp[r.format];
      if (format != null) return _toResult(r, format, f, win);
    }
  }
  // Only the formats zxing-cpp can't read; empty → no Dart work at all.
  return scanFrameAdaptive(f, kind, formats: dart);
}

CodeResult _toResult(
  ZxingResult r,
  CodeFormat format,
  FrameData f,
  ({int left, int top, int side}) win,
) {
  // Corners are full-frame pixels; the overlay wants them window-normalised.
  final pts = <double>[
    for (var i = 0; i + 1 < r.corners.length; i += 2) ...[
      (r.corners[i] - win.left).toDouble(),
      (r.corners[i + 1] - win.top).toDouble(),
    ],
  ];
  return CodeResult(
    r.text,
    format,
    timestamp: f.timestamp,
    isGs1:
        format == CodeFormat.rss14 ||
        format == CodeFormat.rssExpanded ||
        _gs1Ids.contains(r.symbologyIdentifier),
    windowPoints: pts.isEmpty
        ? null
        : mapDecodedPointsToWindow(
            pts,
            win.side,
            win.side,
            false,
            frameOrientation: f.orientation,
            mirrored: f.isMirrored,
          ),
  );
}
