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

  /// Optional GPS geotag written into the photo's EXIF.
  final ({double latitude, double longitude, double altitude})? location;

  const PhotoCaptureOptions({
    this.flash = FlashMode.off,
    this.quality = QualityPrioritization.balanced,
    this.enableShutterSound = true,
    this.skipMetadata = false,
    this.enableAutoRedEyeReduction = true,
    this.location,
  });

  /// Projects onto the FFI struct.
  PhotoOptions toNative() => PhotoOptions(
        flash: flash.nativeValue,
        qualityPrioritization: quality.nativeValue,
        enableShutterSound: enableShutterSound ? 1 : 0,
        skipMetadata: skipMetadata ? 1 : 0,
        enableAutoRedEyeReduction: enableAutoRedEyeReduction ? 1 : 0,
        latitude: location?.latitude ?? 0,
        longitude: location?.longitude ?? 0,
        altitude: location?.altitude ?? 0,
        hasLocation: location != null ? 1 : 0,
      );
}
