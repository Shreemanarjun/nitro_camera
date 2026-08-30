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

  /// Extracts the sub-rectangle [left],[top],[cropWidth]×[cropHeight] (in
  /// source pixels), clamped to the frame bounds, tightly packed. Useful to
  /// analyse only a region of interest (e.g. the same box the scanner uses).
  FrameData cropped(int left, int top, int cropWidth, int cropHeight) {
    final l = left.clamp(0, width);
    final t = top.clamp(0, height);
    final w = cropWidth.clamp(0, width - l);
    final h = cropHeight.clamp(0, height - t);
    if (l == 0 && t == 0 && w == width && h == height) return this;
    final bpp = format == 1 ? 4 : 1;
    final srcStride = effectiveBytesPerRow;
    final out = Uint8List(w * h * bpp);
    for (var y = 0; y < h; y++) {
      final src = (t + y) * srcStride + l * bpp;
      final dst = y * w * bpp;
      for (var i = 0; i < w * bpp; i++) {
        out[dst + i] = bytes[src + i];
      }
    }
    return FrameData(
      bytes: out,
      width: w,
      height: h,
      format: format,
      timestamp: timestamp,
      orientation: orientation,
      isMirrored: isMirrored,
      bytesPerRow: w * bpp,
    );
  }

  /// Rotates the frame by [quarterTurns] × 90° clockwise (mod 4; 0 = no-op),
  /// tightly packed. Normalising a frame upright before an orientation-naive
  /// model is the common use. Note this rotates PIXELS — it does not touch the
  /// [orientation] metadata field.
  FrameData rotated(int quarterTurns) {
    final q = ((quarterTurns % 4) + 4) % 4;
    if (q == 0) return this;
    final bpp = format == 1 ? 4 : 1;
    final srcStride = effectiveBytesPerRow;
    final swap = q == 1 || q == 3; // 90/270 swap dimensions
    final outW = swap ? height : width;
    final outH = swap ? width : height;
    final out = Uint8List(outW * outH * bpp);
    for (var y = 0; y < height; y++) {
      final srcRow = y * srcStride;
      for (var x = 0; x < width; x++) {
        // Destination coordinate for a clockwise rotation.
        final int dx, dy;
        switch (q) {
          case 1: // 90° CW
            dx = height - 1 - y;
            dy = x;
            break;
          case 2: // 180°
            dx = width - 1 - x;
            dy = height - 1 - y;
            break;
          default: // 3 -> 270° CW
            dx = y;
            dy = width - 1 - x;
        }
        final src = srcRow + x * bpp;
        final dst = (dy * outW + dx) * bpp;
        for (var b = 0; b < bpp; b++) {
          out[dst + b] = bytes[src + b];
        }
      }
    }
    return FrameData(
      bytes: out,
      width: outW,
      height: outH,
      format: format,
      timestamp: timestamp,
      orientation: orientation,
      isMirrored: isMirrored,
      bytesPerRow: outW * bpp,
    );
  }
}
