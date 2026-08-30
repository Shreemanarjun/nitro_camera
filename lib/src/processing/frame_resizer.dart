import 'dart:typed_data';

import 'frame_processor.dart' show FrameData;

/// CPU frame resizing for a [FrameData] — the vision-camera-resizer analogue.
///
/// Downscaling frames before handing them to an ML model or a heavier analysis
/// pass is the standard perf move (a detector on 320×240 is far cheaper than on
/// 1920×1080). This is a nearest-neighbour resample of the raw plane, packed
/// tightly (no row padding) in the same [FrameData.format].
///
/// ponytail: CPU nearest-neighbour — fine for the usual "shrink for a model"
/// case and dependency-free. If you need bilinear quality or per-frame 1080p→X
/// at 60fps, move it to the GPU (the native GL renderer is the place).
extension FrameResize on FrameData {
  /// Returns this frame resampled to [targetWidth]×[targetHeight]. The output
  /// carries the same [format]/[orientation]/[isMirrored]; its `bytesPerRow`
  /// is tightly packed. A non-positive target, or an already-matching size,
  /// returns the frame unchanged.
  FrameData resized(int targetWidth, int targetHeight) {
    if (targetWidth <= 0 || targetHeight <= 0) return this;
    if (targetWidth == width && targetHeight == height) return this;

    final bpp = format == 1 ? 4 : 1; // BGRA = 4 bytes, YUV luma plane = 1
    final srcStride = effectiveBytesPerRow;
    final out = Uint8List(targetWidth * targetHeight * bpp);

    for (var y = 0; y < targetHeight; y++) {
      // Map dest row → nearest source row (integer math, no float drift).
      final sy = y * height ~/ targetHeight;
      final srcRow = sy * srcStride;
      final dstRow = y * targetWidth * bpp;
      for (var x = 0; x < targetWidth; x++) {
        final sx = x * width ~/ targetWidth;
        final src = srcRow + sx * bpp;
        final dst = dstRow + x * bpp;
        for (var b = 0; b < bpp; b++) {
          out[dst + b] = bytes[src + b];
        }
      }
    }

    return FrameData(
      bytes: out,
      width: targetWidth,
      height: targetHeight,
      format: format,
      timestamp: timestamp,
      orientation: orientation,
      isMirrored: isMirrored,
      bytesPerRow: targetWidth * bpp, // tightly packed
    );
  }

  /// Resample so the LONGER edge is at most [maxEdge], preserving aspect
  /// ratio (a no-op when already within bounds). Handy for "cap frames at
  /// 640px before the model" without computing the exact target yourself.
  FrameData resizedToMaxEdge(int maxEdge) {
    if (maxEdge <= 0) return this;
    final longEdge = width > height ? width : height;
    if (longEdge <= maxEdge) return this;
    final scale = maxEdge / longEdge;
    final w = (width * scale).round().clamp(1, width);
    final h = (height * scale).round().clamp(1, height);
    return resized(w, h);
  }
}
