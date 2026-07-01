import 'dart:async';
import 'dart:typed_data';

import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/zxing.dart' as zxing;
import 'package:zxing_lib/common.dart' as zxing;

/// A decoded barcode / QR result.
class BarcodeResult {
  final String value;
  final String format;
  const BarcodeResult(this.value, this.format);

  @override
  String toString() => '$format: $value';
}

/// Isolate handler — decodes ONE frame's luma plane. **Top-level** so it can be
/// sent to the worker isolate. Honours the native row stride (padded rows would
/// otherwise decode as noise), and uses `MultiFormatReader` so it reads QR *and*
/// 1D barcodes (EAN/UPC/Code-128/…), not just QR.
BarcodeResult? decodeBarcodeFrame(FrameData f) {
  try {
    final source = _StridedLuminanceSource(
      f.bytes,
      f.width,
      f.height,
      f.effectiveBytesPerRow,
    );
    final bitmap = zxing.BinaryBitmap(zxing.HybridBinarizer(source));
    // `decode` throws when nothing is found (caught below).
    final result = zxing.MultiFormatReader().decode(bitmap);
    return BarcodeResult(result.text, result.barcodeFormat.name);
  } catch (_) {
    return null;
  }
}

/// A performant, reusable Dart-side barcode scanner.
///
/// Improvements over the naïve `compute()`-per-frame approach:
///  * a **single persistent isolate** ([CameraFrameProcessor]) — no ~1–5 ms
///    `Isolate.spawn` cost per frame;
///  * **zero-copy** frame hand-off (`TransferableTypedData`) with drop-latest
///    backpressure, so scanning never stalls the camera/UI;
///  * **stride-correct** luma decoding via [FrameData.effectiveBytesPerRow];
///  * **multi-format** decoding (QR + 1D barcodes).
class DartBarcodeScanner {
  final CameraFrameProcessor<BarcodeResult?> _proc =
      CameraFrameProcessor<BarcodeResult?>(decodeBarcodeFrame);
  StreamSubscription<CameraFrame>? _sub;
  bool _started = false;

  /// Successful scans (nulls / no-detections are filtered out).
  Stream<BarcodeResult> get results =>
      _proc.results.where((r) => r != null).cast<BarcodeResult>();

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
/// stride** (the camera's `bytesPerRow`), copying exactly `width` bytes per row.
class _StridedLuminanceSource extends zxing.LuminanceSource {
  final Uint8List _pixels;
  final int _stride;

  _StridedLuminanceSource(this._pixels, int width, int height, this._stride)
      : super(width, height);

  @override
  Uint8List getRow(int y, Uint8List? row) {
    final res = (row != null && row.length >= width) ? row : Uint8List(width);
    final start = y * _stride;
    final end = start + width;
    if (end <= _pixels.length) {
      res.setRange(0, width, _pixels, start);
    }
    return res;
  }

  @override
  Uint8List get matrix {
    if (_stride == width) return _pixels;
    final m = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      final src = y * _stride;
      if (src + width > _pixels.length) break;
      m.setRange(y * width, y * width + width, _pixels, src);
    }
    return m;
  }

  @override
  bool get isCropSupported => false;
}
