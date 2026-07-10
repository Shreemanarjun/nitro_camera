import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// End-to-end round-trip through the exported scanner engine: encode a QR
/// with zxing_lib, rasterize it into a luma plane, and decode it with the
/// public [decodeCodeFrame] API (the exact path the streaming scanner takes).
FrameData _qrFrame(String text, {int side = 400, int strideExtra = 0}) {
  final matrix = QRCodeWriter().encode(text, BarcodeFormat.qrCode, side, side);
  final stride = side + strideExtra;
  final bytes = Uint8List(stride * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      bytes[y * stride + x] = matrix.get(x, y) ? 0 : 255;
    }
  }
  return FrameData(
    bytes: bytes,
    width: side,
    height: side,
    format: 0, // YUV luma plane — the scanner contract
    bytesPerRow: stride,
  );
}

void main() {
  test('QR round-trip: encode with zxing, decode with decodeCodeFrame', () {
    final result = _qrFrame('https://example.com/nitro?x=1').let(
      (f) => decodeCodeFrame(f, CodeScanKind.qr),
    );
    expect(result, isNotNull);
    expect(result!.text, 'https://example.com/nitro?x=1');
    expect(result.format, CodeFormat.qrCode);
  });

  test('padded row stride decodes identically (bytesPerRow > width)', () {
    final result =
        decodeCodeFrame(_qrFrame('stride-safe', strideExtra: 64), CodeScanKind.qr);
    expect(result, isNotNull);
    expect(result!.text, 'stride-safe');
  });

  test('kind routing: a QR is NOT decoded by the postal kind', () {
    expect(decodeCodeFrame(_qrFrame('hello'), CodeScanKind.postal), isNull);
  });

  test('CodeScanKind.all and .twoD also find the QR', () {
    expect(decodeCodeFrame(_qrFrame('all-kinds'), CodeScanKind.all)?.text,
        'all-kinds');
    expect(decodeCodeFrame(_qrFrame('two-d'), CodeScanKind.twoD)?.text, 'two-d');
  });

  test('windowed scan (0.72 crop) still decodes a centered code', () {
    final result = decodeCodeFrame(
      _qrFrame('windowed', side: 280),
      CodeScanKind.qr,
      windowCropFraction: kScannerWindowFraction,
    );
    // The writer pads with a quiet zone, so a 0.72 center crop of a centered
    // code keeps the full symbol.
    expect(result, isNotNull);
    expect(result!.text, 'windowed');
    // Window points, when reported, are normalized to the displayed window.
    final pts = result.windowPoints;
    if (pts != null) {
      for (final v in pts) {
        expect(v, inInclusiveRange(-0.2, 1.2));
      }
    }
  });

  test('noise does not decode', () {
    final bytes = Uint8List.fromList(
        List.generate(200 * 200, (i) => (i * 2654435761) % 251));
    final noise = FrameData(
        bytes: bytes, width: 200, height: 200, format: 0, bytesPerRow: 200);
    expect(decodeCodeFrame(noise, CodeScanKind.qr), isNull);
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
