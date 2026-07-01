import '../models/camera_device.dart';
import 'constraints.dart';
import '../models/resolved_config.dart';
import '../models/session_state.dart';

/// Negotiates a concrete [CameraDeviceFormat] from a device's available formats
/// and a prioritised list of [CameraConstraint]s.
///
/// This is the Dart-side analogue of vision-camera's native `ConstraintResolver`
/// (iOS penalty-minimization variant): every candidate format is scored by the
/// priority-weighted sum of each constraint's penalty, and the lowest-scoring
/// format wins. Because we already expose the device's formats over the bridge,
/// negotiation can run entirely in Dart — no extra native round-trip.
class FormatResolver {
  const FormatResolver._();

  /// Returns the best-matching format for [device] given [constraints], or
  /// `null` if the device has no formats. With an empty constraint list the
  /// highest-resolution format is returned (a sensible default).
  static CameraDeviceFormat? resolve(
    CameraDeviceInfo device,
    List<CameraConstraint> constraints,
  ) {
    final formats = device.formats;
    if (formats.isEmpty) return null;

    final effective = constraints.isEmpty
        ? const [ResolutionConstraint(TargetResolution.max())]
        : constraints;

    final stats = FormatStats.from(formats);
    final n = effective.length;

    CameraDeviceFormat? best;
    double bestScore = double.infinity;
    for (final format in formats) {
      double score = 0;
      for (var i = 0; i < n; i++) {
        // Priority weight: first constraint (i=0) has the highest weight.
        final weight = (n - i).toDouble();
        score += weight * effective[i].penalty(format, stats);
      }
      if (score < bestScore) {
        bestScore = score;
        best = format;
      }
    }
    return best;
  }

  /// Negotiates a format and produces the [ResolvedCameraConfig] describing what
  /// was actually selected (resolution, clamped fps, HDR availability). Mirrors
  /// vision-camera surfacing the resolved config back via `onSessionConfigSelected`.
  static ResolvedCameraConfig? resolveConfig(
    CameraDeviceInfo device,
    List<CameraConstraint> constraints, {
    double? targetFps,
    PixelFormat pixelFormat = PixelFormat.bgra,
    bool requestVideoHdr = false,
  }) {
    final format = resolve(device, constraints);
    if (format == null) return null;

    // Clamp the requested fps into the negotiated format's supported range.
    final fpsReq = targetFps ?? format.maxFps;
    final selectedFps =
        fpsReq.clamp(format.minFps, format.maxFps).round();

    return ResolvedCameraConfig(
      format: format,
      selectedFps: selectedFps,
      videoWidth: format.videoWidth,
      videoHeight: format.videoHeight,
      photoWidth: format.photoWidth,
      photoHeight: format.photoHeight,
      videoHdrEnabled: requestVideoHdr && format.supportsVideoHdr,
      pixelFormat: pixelFormat,
      autoFocusSystem: format.autoFocusSystem,
    );
  }
}

/// Convenience negotiation helpers on a device, mirroring vision-camera's
/// `getCameraFormat(device, constraints)`.
extension FormatNegotiation on CameraDeviceInfo {
  /// The best format for the given prioritised [constraints]
  /// (highest-resolution format when the list is empty).
  CameraDeviceFormat? bestFormat([List<CameraConstraint> constraints = const []]) =>
      FormatResolver.resolve(this, constraints);
}
