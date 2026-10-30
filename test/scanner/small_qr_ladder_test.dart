import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/common.dart' show BitMatrix;
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// Small-QR regression for the streaming ladder ([scanFrameAdaptive]): a
/// short QR (the qr-server's `NNNN:xxxxxx` payload, version 1) rendered
/// camera-like into 1280×720 luma — area-sampled edges, a blur pass, reduced
/// contrast, sensor noise and per-frame hand jitter — streamed through a fresh
/// worker isolate (fresh ladder/cache globals) per module size.
const _frames = 60;
const _payload = '6267:4ljj10';

/// [modulePx] = rendered pixels per QR module.
FrameData _frame(BitMatrix m, double modulePx, int seed) {
  const fw = 1280, fh = 720;
  final rnd = math.Random(seed);
  final bytes = Uint8List(fw * fh)..fillRange(0, fw * fh, 170);
  final n = m.width; // modules incl. quiet zone
  final size = n * modulePx;
  final ox = (fw - size) / 2 + (rnd.nextDouble() - 0.5) * 40;
  final oy = (fh - size) / 2 + (rnd.nextDouble() - 0.5) * 40;
  const ss = 4; // 4×4 supersampling ≈ a sensor's area integration
  final x0 = ox.floor(), y0 = oy.floor(), x1 = (ox + size).ceil(), y1 = (oy + size).ceil();
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      var dark = 0;
      for (var sy = 0; sy < ss; sy++) {
        final my = ((y + (sy + 0.5) / ss - oy) / modulePx).floor();
        for (var sx = 0; sx < ss; sx++) {
          final mx = ((x + (sx + 0.5) / ss - ox) / modulePx).floor();
          if (mx >= 0 && my >= 0 && mx < n && my < n && m.get(mx, my)) dark++;
        }
      }
      final cover = dark / (ss * ss);
      bytes[y * fw + x] = (215 - cover * 170).round(); // white 215, black 45
    }
  }
  // One 3×3 box blur over the code's footprint (optics/focus softness).
  final blurred = Uint8List.fromList(bytes);
  for (var y = math.max(1, y0 - 2); y < math.min(fh - 1, y1 + 2); y++) {
    for (var x = math.max(1, x0 - 2); x < math.min(fw - 1, x1 + 2); x++) {
      var s = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          s += bytes[(y + dy) * fw + x + dx];
        }
      }
      blurred[y * fw + x] = s ~/ 9;
    }
  }
  for (var i = 0; i < blurred.length; i++) {
    blurred[i] = (blurred[i] + rnd.nextInt(17) - 8).clamp(0, 255);
  }
  return FrameData(bytes: blurred, width: fw, height: fh, format: 0, bytesPerRow: fw);
}

/// Streams [_frames] jittered frames through a fresh worker; returns
/// (hit rate, mean µs per frame).
Future<(double, double)> _stream(double modulePx) => Isolate.run(() {
  scannerWorkerInit(1.0); // full frame, like the benchmark
  final m = QRCodeWriter().encode(_payload, BarcodeFormat.qrCode, 0, 0);
  final frames = [for (var i = 0; i < _frames; i++) _frame(m, modulePx, i)];
  var hits = 0;
  final sw = Stopwatch()..start();
  for (final f in frames) {
    if (scanFrameAdaptive(f, CodeScanKind.qr)?.text == _payload) hits++;
  }
  return (hits / _frames, sw.elapsedMicroseconds / _frames);
});

void main() {
  test('small QRs stream-decode on most frames', () async {
    final rates = <double, double>{};
    for (final px in const [1.75, 2.0, 2.5, 3.0, 4.0, 8.0]) {
      final (rate, us) = await _stream(px);
      rates[px] = rate;
      // ignore: avoid_print
      print('module ${px}px (code ${(29 * px).round()}px): ${(rate * 100).toStringAsFixed(0)}% · ${(us / 1000).toStringAsFixed(2)} ms/frame');
    }
    // Before the upscaled-centre rung: 0 % / 38 % / 92 % at 2.5 / 3 / 4 px
    // (zxing's finder detector needs ≥ ~3 px modules even at full res).
    expect(rates[2.5], greaterThanOrEqualTo(0.9));
    expect(rates[3.0], greaterThanOrEqualTo(0.9));
    expect(rates[4.0], greaterThanOrEqualTo(0.9));
    expect(rates[8.0], greaterThanOrEqualTo(0.9));
  });
}
