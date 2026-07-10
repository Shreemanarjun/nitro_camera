import 'dart:math' show log;

import '../models/camera_device.dart';

/// Which capture stream a resolution constraint targets.
enum StreamType { video, photo }

/// How to negotiate capture resolution against a device's available formats.
///
/// Mirrors vision-camera's resolution "rules": you express *intent*
/// (biggest / smallest / closest-to / don't-care) and the [FormatResolver]
/// picks the concrete [CameraDeviceFormat] that best satisfies it.
sealed class TargetResolution {
  const TargetResolution();

  /// Prefer the highest-resolution format.
  const factory TargetResolution.max() = MaxResolution;

  /// Prefer the lowest-resolution format.
  const factory TargetResolution.min() = MinResolution;

  /// Prefer the format whose resolution is closest to [width] x [height].
  const factory TargetResolution.closestTo(int width, int height) =
      ClosestResolution;

  /// No resolution preference (penalty is always 0).
  const factory TargetResolution.any() = AnyResolution;
}

class MaxResolution extends TargetResolution {
  const MaxResolution();
}

class MinResolution extends TargetResolution {
  const MinResolution();
}

class AnyResolution extends TargetResolution {
  const AnyResolution();
}

class ClosestResolution extends TargetResolution {
  final int width;
  final int height;
  const ClosestResolution(this.width, this.height);
}

/// Aggregate statistics across the candidate formats, used to normalise
/// resolution penalties (so `max`/`min` can be scored relative to the field).
class FormatStats {
  final int minVideoArea;
  final int maxVideoArea;
  final int minPhotoArea;
  final int maxPhotoArea;

  const FormatStats({
    required this.minVideoArea,
    required this.maxVideoArea,
    required this.minPhotoArea,
    required this.maxPhotoArea,
  });

  factory FormatStats.from(List<CameraDeviceFormat> formats) {
    var minV = 1 << 62, maxV = 0, minP = 1 << 62, maxP = 0;
    for (final f in formats) {
      final v = f.videoWidth * f.videoHeight;
      final p = f.photoWidth * f.photoHeight;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
      if (p < minP) minP = p;
      if (p > maxP) maxP = p;
    }
    if (formats.isEmpty) {
      minV = maxV = minP = maxP = 0;
    }
    return FormatStats(
      minVideoArea: minV,
      maxVideoArea: maxV,
      minPhotoArea: minP,
      maxPhotoArea: maxP,
    );
  }
}

/// A single prioritised capture constraint.
///
/// Constraints are supplied as an *ordered* list — the first element is the
/// highest priority. Each constraint contributes a [penalty] in `[0, 1]` for a
/// candidate format; the [FormatResolver] minimises the priority-weighted sum,
/// so higher-priority constraints dominate. This is the Dart analogue of
/// vision-camera's native `ConstraintResolver`.
sealed class CameraConstraint {
  const CameraConstraint();

  /// Penalty in `[0, 1]` for [format]; 0 = perfect, 1 = worst. [stats] provides
  /// field-wide min/max areas so relative rules (`max`/`min`) can normalise.
  double penalty(CameraDeviceFormat format, FormatStats stats);
}

/// Prefer a format supporting [fps]. Penalty grows with distance from the
/// format's `[minFps, maxFps]` range.
class FpsConstraint extends CameraConstraint {
  final double fps;
  const FpsConstraint(this.fps);

  @override
  double penalty(CameraDeviceFormat format, FormatStats stats) {
    if (fps >= format.minFps && fps <= format.maxFps) return 0;
    final d = fps < format.minFps ? format.minFps - fps : fps - format.maxFps;
    // Normalise by a plausible fps span (240) and clamp.
    return (d / 240.0).clamp(0.0, 1.0);
  }
}

/// Prefer a resolution according to [target] for the given [stream].
class ResolutionConstraint extends CameraConstraint {
  final TargetResolution target;
  final StreamType stream;
  const ResolutionConstraint(this.target, {this.stream = StreamType.video});

  @override
  double penalty(CameraDeviceFormat format, FormatStats stats) {
    final isVideo = stream == StreamType.video;
    final w = isVideo ? format.videoWidth : format.photoWidth;
    final h = isVideo ? format.videoHeight : format.photoHeight;
    final area = w * h;
    final minArea = isVideo ? stats.minVideoArea : stats.minPhotoArea;
    final maxArea = isVideo ? stats.maxVideoArea : stats.maxPhotoArea;
    final span = (maxArea - minArea);

    switch (target) {
      case AnyResolution():
        return 0;
      case MaxResolution():
        if (span <= 0) return 0;
        return ((maxArea - area) / span).clamp(0.0, 1.0);
      case MinResolution():
        if (span <= 0) return 0;
        return ((area - minArea) / span).clamp(0.0, 1.0);
      case ClosestResolution(:final width, :final height):
        final targetArea = width * height;
        if (targetArea <= 0 || area <= 0) return 0;
        // vision-camera v5's Size.penalty (Sizes+sortedByClosestTo.kt):
        // scale-invariant log-pixel distance + a hard aspect-mismatch weight
        // (aspect compared long/short so orientation doesn't matter). We
        // normalise the open-ended sum into [0, 1] with x/(1+x) to fit the
        // constraint contract.
        double longShort(num a, num b) =>
            a >= b ? a / (b == 0 ? 1 : b) : b / (a == 0 ? 1 : a);
        final targetAr = longShort(width, height);
        final actualAr = longShort(w, h);
        final arDiff = (actualAr - targetAr).abs() / targetAr;
        final aspectPenalty = arDiff < 0.02 ? 0.0 : 3.0 * arDiff;
        final logPixelDistance = (log(area / targetArea)).abs();
        final raw = aspectPenalty + logPixelDistance;
        return raw / (1.0 + raw);
    }
  }
}

/// Require video-HDR support (penalty 1 if the format can't do it).
class VideoHdrConstraint extends CameraConstraint {
  final bool enabled;
  const VideoHdrConstraint(this.enabled);

  @override
  double penalty(CameraDeviceFormat format, FormatStats stats) =>
      (enabled && !format.supportsVideoHdr) ? 1 : 0;
}

/// Require photo-HDR support (penalty 1 if the format can't do it).
class PhotoHdrConstraint extends CameraConstraint {
  final bool enabled;
  const PhotoHdrConstraint(this.enabled);

  @override
  double penalty(CameraDeviceFormat format, FormatStats stats) =>
      (enabled && !format.supportsPhotoHdr) ? 1 : 0;
}

/// Prefer a format that supports the given video-stabilization [mode].
/// Penalty 1 if unsupported.
class VideoStabilizationConstraint extends CameraConstraint {
  final VideoStabilizationMode mode;
  const VideoStabilizationConstraint(this.mode);

  @override
  double penalty(CameraDeviceFormat format, FormatStats stats) =>
      format.videoStabilizationModes.contains(mode) ? 0 : 1;
}

/// Prefer a format whose auto-focus system matches [system].
class AutoFocusConstraint extends CameraConstraint {
  final AutoFocusSystem system;
  const AutoFocusConstraint(this.system);

  @override
  double penalty(CameraDeviceFormat format, FormatStats stats) =>
      format.autoFocusSystem == system ? 0 : 1;
}
