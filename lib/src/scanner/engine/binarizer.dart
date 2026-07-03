import 'dart:typed_data';

/// A binarized view over a window of a strided 8-bit luma plane.
///
/// The threshold is computed once (Otsu over the window histogram); pixel
/// tests are then O(1). All coordinates passed to [dark] are window-relative.
class GrayWindow {
  final Uint8List luma;
  final int stride;
  final int left;
  final int top;
  final int width;
  final int height;
  late final int threshold = _otsu();

  GrayWindow(
    this.luma, {
    required this.stride,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  bool dark(int x, int y) {
    final idx = (top + y) * stride + left + x;
    // <=: Otsu returns the last value of the dark class (inclusive).
    return idx >= 0 && idx < luma.length && luma[idx] <= threshold;
  }

  int _otsu() {
    final hist = List<int>.filled(256, 0);
    var total = 0;
    for (var y = 0; y < height; y++) {
      final row = (top + y) * stride + left;
      for (var x = 0; x < width; x++) {
        final idx = row + x;
        if (idx >= 0 && idx < luma.length) {
          hist[luma[idx]]++;
          total++;
        }
      }
    }
    if (total == 0) return 127;
    var sum = 0;
    for (var i = 0; i < 256; i++) {
      sum += i * hist[i];
    }
    var sumB = 0, wB = 0;
    var maxVar = -1.0, threshold = 127;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final v = wB.toDouble() * wF.toDouble() * (mB - mF) * (mB - mF);
      if (v > maxVar) {
        maxVar = v;
        threshold = t;
      }
    }
    return threshold;
  }
}
