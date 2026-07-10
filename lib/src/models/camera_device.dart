import 'dart:convert';

import 'camera_exception.dart';

import '../nitro_camera.native.dart'
    show CameraPosition, CameraLensType, VideoStabilizationMode;

export '../nitro_camera.native.dart'
    show CameraPosition, CameraLensType, VideoStabilizationMode;

/// Camera2 `INFO_SUPPORTED_HARDWARE_LEVEL` tiers (always [full] on iOS).
enum HardwareLevel {
  legacy('legacy'),
  limited('limited'),
  full('full');

  /// The JSON wire value (same string as vision-camera).
  final String value;
  const HardwareLevel(this.value);

  static HardwareLevel fromValue(String? v) => values.firstWhere(
        (e) => e.value == v,
        orElse: () => HardwareLevel.full,
      );
}

/// The auto-focus system of a capture format.
enum AutoFocusSystem {
  none('none'),
  contrastDetection('contrast-detection'),
  phaseDetection('phase-detection');

  /// The JSON wire value (same string as vision-camera).
  final String value;
  const AutoFocusSystem(this.value);

  static AutoFocusSystem fromValue(String? v) => values.firstWhere(
        (e) => e.value == v,
        orElse: () => AutoFocusSystem.none,
      );
}

/// The physical lens types backing a (possibly logical) camera device.
/// Wire values match vision-camera's `PhysicalCameraDeviceType`.
enum PhysicalDeviceType {
  ultraWideAngleCamera('ultra-wide-angle-camera'),
  wideAngleCamera('wide-angle-camera'),
  telephotoCamera('telephoto-camera');

  final String value;
  const PhysicalDeviceType(this.value);

  static PhysicalDeviceType? tryFromValue(String v) {
    for (final e in values) {
      if (e.value == v) return e;
    }
    return null;
  }
}

/// Vendor camera extensions (Android `CameraExtensionCharacteristics`,
/// API 31+; always absent on iOS). Query-only for now — extension capture
/// sessions are a planned feature.
enum CameraExtension {
  auto('auto'),
  faceRetouch('face-retouch'),
  bokeh('bokeh'),
  hdr('hdr'),
  night('night');

  final String value;
  const CameraExtension(this.value);

  static CameraExtension? tryFromValue(String v) {
    for (final e in values) {
      if (e.value == v) return e;
    }
    return null;
  }
}

/// Vision-camera-compatible camera device info, parsed from the native JSON.
///
/// Obtain via [CameraController.getAvailableCameraDevices].
class CameraDeviceInfo {
  final String id;
  final String name;

  /// Which way the camera faces.
  final CameraPosition position;

  /// The lens kind (wide / ultra-wide / telephoto) of this device.
  final CameraLensType lensType;

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

  final HardwareLevel hardwareLevel;

  /// The underlying physical lenses (one entry for a plain camera; the
  /// constituent lenses for a logical multi-cam device).
  final List<PhysicalDeviceType> physicalDevices;

  /// Vendor camera extensions available on this device (API 31+).
  final List<CameraExtension> extensions;

  final double focalLength;
  final double aperture;

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
    this.hardwareLevel = HardwareLevel.full,
    this.physicalDevices = const [],
    this.extensions = const [],
    this.formats = const [],
    this.focalLength = 3.5,
    this.aperture = 1.8,
  });

  // Unknown wire indices (native/plugin version skew) parse to a safe default
  // instead of a RangeError.
  static CameraPosition _positionFrom(int i) =>
      (i >= 0 && i < CameraPosition.values.length)
          ? CameraPosition.values[i]
          : CameraPosition.external;

  static CameraLensType _lensTypeFrom(int i) =>
      (i >= 0 && i < CameraLensType.values.length)
          ? CameraLensType.values[i]
          : CameraLensType.unknown;

  factory CameraDeviceInfo.fromJson(Map<String, dynamic> json) {
    final fmts = (json['formats'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(CameraDeviceFormat.fromJson)
        .toList();
    // Unknown lens/extension wire strings are skipped, not errors — a newer
    // native layer may report kinds this Dart side doesn't know yet.
    final physical = (json['physicalDevices'] as List? ?? [])
        .cast<String>()
        .map(PhysicalDeviceType.tryFromValue)
        .nonNulls
        .toList();
    final extensions = (json['extensions'] as List? ?? [])
        .cast<String>()
        .map(CameraExtension.tryFromValue)
        .nonNulls
        .toList();
    return CameraDeviceInfo(
      id:                  json['id'] as String,
      name:                json['name'] as String,
      position:            _positionFrom((json['position'] as num).toInt()),
      lensType:            _lensTypeFrom((json['lensType'] as num).toInt()),
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
      hardwareLevel:       HardwareLevel.fromValue(json['hardwareLevel'] as String?),
      physicalDevices:     physical,
      extensions:          extensions,
      formats:             fmts,
      focalLength:         (json['focalLength'] as num? ?? 3.5).toDouble(),
      aperture:            (json['aperture'] as num? ?? 1.8).toDouble(),
    );
  }

  /// Parse a JSON array string returned by [NitroCamera.getAvailableCameraDevicesJson].
  ///
  /// Throws a [SessionException] (`session/malformed-payload`) on a malformed
  /// payload — an empty list always means "no cameras", never a swallowed
  /// parse error.
  static List<CameraDeviceInfo> listFromJson(String jsonStr) {
    try {
      final list = jsonDecode(jsonStr) as List;
      return list.cast<Map<String, dynamic>>().map(CameraDeviceInfo.fromJson).toList();
    } catch (e) {
      throw SessionException.malformedPayload('camera-device', e);
    }
  }

  /// Convenience: whether this device faces away from the user.
  bool get isBackCamera => position == CameraPosition.back;

  /// Convenience: whether this device faces the user.
  bool get isFrontCamera => position == CameraPosition.front;

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

  final AutoFocusSystem autoFocusSystem;

  /// Which stabilization modes this format supports (always contains
  /// [VideoStabilizationMode.off]).
  final List<VideoStabilizationMode> videoStabilizationModes;

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
    this.autoFocusSystem = AutoFocusSystem.none,
    this.videoStabilizationModes = const [VideoStabilizationMode.off],
  });

  // Wire strings for VideoStabilizationMode (same as vision-camera).
  static const _stabilizationValues = {
    'off': VideoStabilizationMode.off,
    'standard': VideoStabilizationMode.standard,
    'cinematic': VideoStabilizationMode.cinematic,
    'cinematic-extended': VideoStabilizationMode.cinematicExtended,
    'auto': VideoStabilizationMode.auto,
  };

  factory CameraDeviceFormat.fromJson(Map<String, dynamic> json) {
    final modes = (json['videoStabilizationModes'] as List? ?? ['off'])
        .cast<String>()
        .map((s) => _stabilizationValues[s])
        .nonNulls
        .toList();
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
      autoFocusSystem:
          AutoFocusSystem.fromValue(json['autoFocusSystem'] as String?),
      videoStabilizationModes:
          modes.isEmpty ? const [VideoStabilizationMode.off] : modes,
    );
  }

  @override
  String toString() => 'CameraDeviceFormat(${videoWidth}x$videoHeight@${maxFps}fps)';
}
