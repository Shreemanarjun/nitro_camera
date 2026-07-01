import 'camera_device.dart';
import 'session_state.dart';

/// The concrete configuration that negotiation actually selected.
///
/// Analogous to vision-camera's `CameraSessionConfig` that is surfaced back to
/// JS via `onSessionConfigSelected` — it lets the UI display / react to what the
/// camera really chose (which may differ from what was requested).
class ResolvedCameraConfig {
  /// The format that was selected by the [FormatResolver].
  final CameraDeviceFormat format;

  /// The frame rate actually used, clamped into the format's supported range.
  final int selectedFps;

  final int videoWidth;
  final int videoHeight;
  final int photoWidth;
  final int photoHeight;

  /// Whether video-HDR was requested *and* is supported by [format].
  final bool videoHdrEnabled;

  /// The pixel format used for the frame stream.
  final PixelFormat pixelFormat;

  /// The auto-focus system of the selected format.
  final String autoFocusSystem;

  const ResolvedCameraConfig({
    required this.format,
    required this.selectedFps,
    required this.videoWidth,
    required this.videoHeight,
    required this.photoWidth,
    required this.photoHeight,
    required this.videoHdrEnabled,
    required this.pixelFormat,
    required this.autoFocusSystem,
  });

  double get aspectRatio => videoHeight == 0 ? 0 : videoWidth / videoHeight;

  @override
  String toString() =>
      'ResolvedCameraConfig(${videoWidth}x$videoHeight@${selectedFps}fps, '
      'hdr=$videoHdrEnabled, pixelFormat=${pixelFormat.name})';
}
