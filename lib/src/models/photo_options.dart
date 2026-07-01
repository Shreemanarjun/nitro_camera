import '../nitro_camera.native.dart';

/// Type-safe options for a single photo capture (`CameraController.takePhoto`).
///
/// Wraps the FFI [PhotoOptions] struct with enums / bools.
class PhotoCaptureOptions {
  /// Flash for this capture.
  final FlashMode flash;

  /// Speed-vs-quality tradeoff.
  final QualityPrioritization quality;

  final bool enableShutterSound;

  /// Skip embedding EXIF / metadata.
  final bool skipMetadata;

  final bool enableAutoRedEyeReduction;

  const PhotoCaptureOptions({
    this.flash = FlashMode.off,
    this.quality = QualityPrioritization.balanced,
    this.enableShutterSound = true,
    this.skipMetadata = false,
    this.enableAutoRedEyeReduction = true,
  });

  /// Projects onto the FFI struct.
  PhotoOptions toNative() => PhotoOptions(
        flash: flash.nativeValue,
        qualityPrioritization: quality.nativeValue,
        enableShutterSound: enableShutterSound ? 1 : 0,
        skipMetadata: skipMetadata ? 1 : 0,
        enableAutoRedEyeReduction: enableAutoRedEyeReduction ? 1 : 0,
      );
}
