import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// Rasterizes a QR of [qr]px into a larger [frame]px white luma plane at
/// pixel offset ([ox], [oy]) — so the code sits OFF-center. The scan window
/// (a centered square fraction of the short side) should include it only when
/// large enough.
FrameData _offsetQrFrame(
  String text, {
  int frame = 800,
  int qr = 260,
  required int ox,
  required int oy,
}) {
  final matrix = QRCodeWriter().encode(text, BarcodeFormat.qrCode, qr, qr);
  final bytes = Uint8List(frame * frame)..fillRange(0, frame * frame, 255);
  for (var y = 0; y < qr; y++) {
    for (var x = 0; x < qr; x++) {
      bytes[(oy + y) * frame + (ox + x)] = matrix.get(x, y) ? 0 : 255;
    }
  }
  return FrameData(
    bytes: bytes,
    width: frame,
    height: frame,
    format: 0, // YUV luma
    timestamp: 0,
    orientation: 0,
    isMirrored: false,
    bytesPerRow: frame,
  );
}

void main() {
  const url = 'https://example.com/roi';

  test('a centered QR decodes at both a full and a small window', () {
    // Centered: 260px QR in an 800px frame, centered at (270,270).
    final f = _offsetQrFrame(url, ox: 270, oy: 270);
    expect(decodeCodeFrame(f, CodeScanKind.qr, windowCropFraction: 1.0)?.text, url);
    // 0.45 * 800 = 360px centered box (220..580) still covers 270..530.
    expect(decodeCodeFrame(f, CodeScanKind.qr, windowCropFraction: 0.45)?.text, url);
  });

  test('an off-center QR is found at full window but rejected by a small ROI', () {
    // QR in the top-left corner (0..260); the centered short-side window
    // must be wide enough to reach it.
    final f = _offsetQrFrame(url, ox: 8, oy: 8);
    // Full frame — found.
    expect(decodeCodeFrame(f, CodeScanKind.qr, windowCropFraction: 1.0)?.text, url);
    // Small centered ROI (0.3 -> 240px box centered at 400 = 280..520) excludes
    // the corner QR — must NOT decode. This is the ROI doing its job.
    expect(decodeCodeFrame(f, CodeScanKind.qr, windowCropFraction: 0.3), isNull);
  });
}
