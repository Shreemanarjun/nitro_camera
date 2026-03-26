import 'dart:convert';

/// Vision-camera-compatible camera device info, parsed from the native JSON.
///
/// Obtain via [CameraController.getAvailableCameraDevices].
class CameraDeviceInfo {
  final String id;
  final String name;

  /// 0 = front, 1 = back, 2 = external
  final int position;

  /// 0 = unknown, 1 = wide-angle, 2 = ultra-wide, 3 = telephoto
  final int lensType;

  /// Degrees: 0 / 90 / 180 / 270
  final int sensorOrientation;

  final double minZoom;
  final double maxZoom;

  /// Neutral zoom factor for multi-camera virtual devices.
  final double neutralZoom;

  final bool hasFlash;
  final bool hasTorch;

  final int maxPhotoWidth;
  final int maxPhotoHeight;

  /// Minimum exposure bias (EV).
  final double minExposure;

  /// Maximum exposure bias (EV).
  final double maxExposure;

  /// Minimum focus distance in centimetres. 0 = infinity (fixed-focus).
  final double minFocusDistanceCm;

  /// True if this is a virtual multi-camera backed by multiple physical lenses.
  final bool isMultiCam;

  final bool supportsLowLightBoost;
  final bool supportsRawCapture;
  final bool supportsFocus;

  /// "legacy" | "limited" | "full"
  final String hardwareLevel;

  /// Identifiers of the underlying physical cameras (e.g. "wide-angle-camera").
  final List<String> physicalDevices;

  /// Available capture formats, sorted by descending resolution.
  final List<CameraDeviceFormat> formats;

  const CameraDeviceInfo({
    required this.id,
    required this.name,
    required this.position,
    required this.lensType,
    required this.sensorOrientation,
    required this.minZoom,
    required this.maxZoom,
    required this.neutralZoom,
    required this.hasFlash,
    required this.hasTorch,
    required this.maxPhotoWidth,
    required this.maxPhotoHeight,
    this.minExposure = -4.0,
    this.maxExposure = 4.0,
    this.minFocusDistanceCm = 0.0,
    this.isMultiCam = false,
    this.supportsLowLightBoost = false,
    this.supportsRawCapture = false,
    this.supportsFocus = true,
    this.hardwareLevel = 'full',
    this.physicalDevices = const [],
    this.formats = const [],
  });

  factory CameraDeviceInfo.fromJson(Map<String, dynamic> json) {
    final fmts = (json['formats'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(CameraDeviceFormat.fromJson)
        .toList();
    final physical = (json['physicalDevices'] as List? ?? []).cast<String>();
    return CameraDeviceInfo(
      id:                  json['id'] as String,
      name:                json['name'] as String,
      position:            (json['position'] as num).toInt(),
      lensType:            (json['lensType'] as num).toInt(),
      sensorOrientation:   (json['sensorOrientation'] as num).toInt(),
      minZoom:             (json['minZoom'] as num).toDouble(),
      maxZoom:             (json['maxZoom'] as num).toDouble(),
      neutralZoom:         (json['neutralZoom'] as num? ?? 1).toDouble(),
      hasFlash:            json['hasFlash'] == true || json['hasFlash'] == 1,
      hasTorch:            json['hasTorch'] == true || json['hasTorch'] == 1,
      maxPhotoWidth:       (json['maxPhotoWidth'] as num).toInt(),
      maxPhotoHeight:      (json['maxPhotoHeight'] as num).toInt(),
      minExposure:         (json['minExposure'] as num? ?? -4).toDouble(),
      maxExposure:         (json['maxExposure'] as num? ?? 4).toDouble(),
      minFocusDistanceCm:  (json['minFocusDistanceCm'] as num? ?? 0).toDouble(),
      isMultiCam:          json['isMultiCam'] == true,
      supportsLowLightBoost: json['supportsLowLightBoost'] == true,
      supportsRawCapture:  json['supportsRawCapture'] == true,
      supportsFocus:       json['supportsFocus'] != false,
      hardwareLevel:       json['hardwareLevel'] as String? ?? 'full',
      physicalDevices:     physical,
      formats:             fmts,
    );
  }

  /// Parse a JSON array string returned by [NitroCamera.getAvailableCameraDevicesJson].
  static List<CameraDeviceInfo> listFromJson(String jsonStr) {
    try {
      final list = jsonDecode(jsonStr) as List;
      return list.cast<Map<String, dynamic>>().map(CameraDeviceInfo.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  /// Convenience: back-facing cameras sorted by descending zoom (wide → tele).
  bool get isBackCamera => position == 1;

  /// Convenience: front-facing camera.
  bool get isFrontCamera => position == 0;

  @override
  String toString() => 'CameraDeviceInfo($id, $name)';
}

/// A capture format available on a [CameraDeviceInfo].
///
/// Mirrors vision-camera's `CameraDeviceFormat`.
class CameraDeviceFormat {
  final int photoWidth;
  final int photoHeight;
  final int videoWidth;
  final int videoHeight;
  final double minFps;
  final double maxFps;
  final double minISO;
  final double maxISO;

  /// Horizontal field of view in degrees.
  final double fieldOfView;

  final bool supportsVideoHdr;
  final bool supportsPhotoHdr;
  final bool supportsDepthCapture;

  /// "none" | "contrast-detection" | "phase-detection"
  final String autoFocusSystem;

  /// e.g. ["off", "standard", "cinematic"]
  final List<String> videoStabilizationModes;

  const CameraDeviceFormat({
    required this.photoWidth,
    required this.photoHeight,
    required this.videoWidth,
    required this.videoHeight,
    required this.minFps,
    required this.maxFps,
    this.minISO = 25.0,
    this.maxISO = 3200.0,
    this.fieldOfView = 69.4,
    this.supportsVideoHdr = false,
    this.supportsPhotoHdr = false,
    this.supportsDepthCapture = false,
    this.autoFocusSystem = 'none',
    this.videoStabilizationModes = const ['off'],
  });

  factory CameraDeviceFormat.fromJson(Map<String, dynamic> json) {
    final modes = (json['videoStabilizationModes'] as List? ?? ['off']).cast<String>();
    return CameraDeviceFormat(
      photoWidth:              (json['photoWidth'] as num).toInt(),
      photoHeight:             (json['photoHeight'] as num).toInt(),
      videoWidth:              (json['videoWidth'] as num).toInt(),
      videoHeight:             (json['videoHeight'] as num).toInt(),
      minFps:                  (json['minFps'] as num).toDouble(),
      maxFps:                  (json['maxFps'] as num).toDouble(),
      minISO:                  (json['minISO'] as num? ?? 25).toDouble(),
      maxISO:                  (json['maxISO'] as num? ?? 3200).toDouble(),
      fieldOfView:             (json['fieldOfView'] as num? ?? 69.4).toDouble(),
      supportsVideoHdr:        json['supportsVideoHdr'] == true,
      supportsPhotoHdr:        json['supportsPhotoHdr'] == true,
      supportsDepthCapture:    json['supportsDepthCapture'] == true,
      autoFocusSystem:         json['autoFocusSystem'] as String? ?? 'none',
      videoStabilizationModes: modes,
    );
  }

  @override
  @override
  String toString() => 'CameraDeviceFormat(${videoWidth}x$videoHeight@${maxFps}fps)';
}
