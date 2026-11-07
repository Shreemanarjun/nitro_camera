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

  /// Optional reusable storage for [mask] (at least `width × height` bytes),
  /// so a per-frame scan doesn't allocate a fresh full-window buffer.
  final Uint8List? _maskStorage;

  GrayWindow(
    this.luma, {
    required this.stride,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    Uint8List? maskStorage,
  }) : _maskStorage = maskStorage;

  bool dark(int x, int y) {
    if (x >= 0 && x < width && y >= 0 && y < height) return mask[y * width + x] != 0;
    // Outside the window (e.g. x = 0 of a zero-width window): read the plane
    // directly, exactly as before the mask existed.
    final idx = (top + y) * stride + left + x;
    return idx >= 0 && idx < luma.length && luma[idx] <= threshold;
  }

  /// Row-major `width × height` dark mask (1 = dark), built once: callers
  /// that sweep every pixel read this instead of re-thresholding per call.
  late final Uint8List mask = _buildMask();

  Uint8List _buildMask() {
    final size = width * height;
    final s = _maskStorage;
    final m = (s != null && s.length >= size) ? Uint8List.sublistView(s, 0, size) : Uint8List(size);
    final t = threshold, n = luma.length;
    for (var y = 0; y < height; y++) {
      final row = (top + y) * stride + left, o = y * width;
      for (var x = 0; x < width; x++) {
        final idx = row + x;
        // <=: Otsu returns the last value of the dark class (inclusive).
        // Every byte is written: reused storage needs no clearing.
        m[o + x] = (idx >= 0 && idx < n && luma[idx] <= t) ? 1 : 0;
      }
    }
    return m;
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
