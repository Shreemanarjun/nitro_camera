import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:flutter/services.dart' show rootBundle;
import 'package:nitro_camera/nitro_camera.dart';

import 'bench_stats.dart';

const _imageRepeats = 30; // IMAGE_REPEATS in the RN bench
const _imageAsset =
    'assets/bench/qr-code-margelo.png'; // identical bytes to the RN bench

/// Decodes the bundled PNG to a luma plane and scans it [_imageRepeats]
/// times on a fresh isolate (off the UI thread, like the RN native scan).
Future<BenchResult> runImageBench(CodeScanKind kind) async {
  final png = (await rootBundle.load(_imageAsset)).buffer.asUint8List();
  final image = await decodeImageFromList(png);
  final w = image.width, h = image.height;
  final rgba = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
  image.dispose();
  final luma = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    luma[i] =
        (rgba[i * 4] * 299 + rgba[i * 4 + 1] * 587 + rgba[i * 4 + 2] * 114) ~/
        1000;
  }
  final samples = await Isolate.run(() {
    final f = FrameData(
      bytes: luma,
      width: w,
      height: h,
      format: 0,
      bytesPerRow: w,
    );
    decodeCodeFrame(f, kind); // warm-up, not measured
    final out = <(double, String)>[];
    final sw = Stopwatch();
    for (var i = 0; i < _imageRepeats; i++) {
      sw
        ..reset()
        ..start();
      final r = decodeCodeFrame(f, kind);
      sw.stop();
      out.add((sw.elapsedMicroseconds / 1000, r?.text ?? ''));
    }
    return out;
  });
  final col = Collector();
  for (final (ms, value) in samples) {
    col.scan(ms);
    if (value.isNotEmpty) col.hit(value);
  }
  return col.result('Bundled QR image', '${w}x$h PNG · $_imageRepeats scans');
}
