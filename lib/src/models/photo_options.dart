import 'package:meta/meta.dart' show internal;

import '../nitro_camera.native.dart';

/// The photo file container written by a capture.
enum PhotoOutputFormat {
  /// Processed JPEG (default).
  jpeg,

  /// Adobe DNG — the RAW sensor data (vision-camera's `containerFormat:
  /// 'dng'`). Requires [CameraDeviceInfo.supportsRawCapture]; capture is
  /// slower (the session pauses briefly to route the RAW stream).
  dng,
}

/// The container and RAW-ness of a captured [PhotoResult] — vision-camera's
/// `PhotoFile.containerFormat` / `isRawPhoto` (v5.2.4 #4170). Read from the
/// file both platforms write: `.dng` for RAW captures, `.jpg` otherwise.
extension PhotoResultFormat on PhotoResult {
  PhotoOutputFormat get containerFormat => path.toLowerCase().endsWith('.dng') ? PhotoOutputFormat.dng : PhotoOutputFormat.jpeg;

  bool get isRawPhoto => containerFormat == PhotoOutputFormat.dng;
}

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

  /// File container: processed [PhotoOutputFormat.jpeg] (default) or RAW
  /// [PhotoOutputFormat.dng].
  final PhotoOutputFormat outputFormat;

  const PhotoCaptureOptions({
    this.flash = FlashMode.off,
    this.quality = QualityPrioritization.balanced,
    this.enableShutterSound = true,
    this.skipMetadata = false,
    this.enableAutoRedEyeReduction = true,
    this.location,
    this.outputFormat = PhotoOutputFormat.jpeg,
  });

  /// Projects onto the FFI struct.
  @internal
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
    outputFormat: outputFormat.index,
  );
}
