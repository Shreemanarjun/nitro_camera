import '../models/camera_device.dart';
// Full import (not `show`) so the generated `nativeValue` enum extensions in the
// `part` file are visible here.
import '../nitro_camera.native.dart';
import '../models/session_state.dart';

/// Immutable, declarative description of a desired camera session state.
///
/// This is the Flutter/FFI adaptation of vision-camera's declarative session
/// configuration: instead of calling N imperative setters, you hold one
/// [CameraConfiguration], derive a new one with [copyWith], and hand it to
/// `CameraController.configure`, which computes a [CameraConfigurationDiff] and
/// applies only what changed (reopening the session only when it must).
class CameraConfiguration {
  /// Target device id. Changing this forces a full session reopen.
  final String? deviceId;

  /// The negotiated (or explicitly chosen) capture format. Changing the video
  /// resolution / fps forces a reopen.
  final CameraDeviceFormat? format;

  /// Target frame rate. Changing it forces a reopen.
  final int fps;

  /// Whether to capture audio for video recording. Changing forces a reopen.
  final bool enableAudio;

  /// Whether the preview is running. Toggling only starts/stops streaming.
  final bool isActive;

  // ---- Live device-config (cheap; no session teardown) ----
  final double zoom;
  final double exposure;
  final FlashMode flash;
  final bool torch;

  /// White-balance colour temperature in Kelvin; 0 = auto.
  final int whiteBalanceKelvin;
  final bool videoHdr;
  final bool lowLightBoost;
  final VideoStabilizationMode videoStabilization;
  final AutoFocusMode autoFocus;

  // ---- Frame processing ----
  final bool enableFrameProcessing;

  /// The frame-stream pixel format.
  final PixelFormat pixelFormat;

  /// Deliver every Nth frame to the frame stream (1 = every frame).
  final int samplingRate;

  /// GLSL fragment-shader source applied to the preview (`''` = none).
  final String filterShader;

  const CameraConfiguration({
    this.deviceId,
    this.format,
    this.fps = 30,
    this.enableAudio = false,
    this.isActive = true,
    this.zoom = 1.0,
    this.exposure = 0.0,
    this.flash = FlashMode.off,
    this.torch = false,
    this.whiteBalanceKelvin = 0,
    this.videoHdr = false,
    this.lowLightBoost = false,
    this.videoStabilization = VideoStabilizationMode.off,
    this.autoFocus = AutoFocusMode.continuous,
    this.enableFrameProcessing = false,
    this.pixelFormat = PixelFormat.bgra,
    this.samplingRate = 1,
    this.filterShader = '',
  });

  CameraConfiguration copyWith({
    String? deviceId,
    CameraDeviceFormat? format,
    int? fps,
    bool? enableAudio,
    bool? isActive,
    double? zoom,
    double? exposure,
    FlashMode? flash,
    bool? torch,
    int? whiteBalanceKelvin,
    bool? videoHdr,
    bool? lowLightBoost,
    VideoStabilizationMode? videoStabilization,
    AutoFocusMode? autoFocus,
    bool? enableFrameProcessing,
    PixelFormat? pixelFormat,
    int? samplingRate,
    String? filterShader,
  }) {
    return CameraConfiguration(
      deviceId: deviceId ?? this.deviceId,
      format: format ?? this.format,
      fps: fps ?? this.fps,
      enableAudio: enableAudio ?? this.enableAudio,
      isActive: isActive ?? this.isActive,
      zoom: zoom ?? this.zoom,
      exposure: exposure ?? this.exposure,
      flash: flash ?? this.flash,
      torch: torch ?? this.torch,
      whiteBalanceKelvin: whiteBalanceKelvin ?? this.whiteBalanceKelvin,
      videoHdr: videoHdr ?? this.videoHdr,
      lowLightBoost: lowLightBoost ?? this.lowLightBoost,
      videoStabilization: videoStabilization ?? this.videoStabilization,
      autoFocus: autoFocus ?? this.autoFocus,
      enableFrameProcessing:
          enableFrameProcessing ?? this.enableFrameProcessing,
      pixelFormat: pixelFormat ?? this.pixelFormat,
      samplingRate: samplingRate ?? this.samplingRate,
      filterShader: filterShader ?? this.filterShader,
    );
  }

  /// Computes what changed between [previous] and this configuration.
  CameraConfigurationDiff diff(CameraConfiguration? previous) {
    if (previous == null) {
      // First apply: everything that differs from a fresh session is "changed".
      return const CameraConfigurationDiff._all();
    }
    // A device/format/fps/audio change requires tearing down the session.
    final device = deviceId != previous.deviceId ||
        fps != previous.fps ||
        enableAudio != previous.enableAudio ||
        _formatKey(format) != _formatKey(previous.format);
    return CameraConfigurationDiff._(
      device: device,
      isActive: isActive != previous.isActive,
      zoom: zoom != previous.zoom,
      exposure: exposure != previous.exposure,
      flash: flash != previous.flash,
      torch: torch != previous.torch,
      whiteBalance: whiteBalanceKelvin != previous.whiteBalanceKelvin,
      videoHdr: videoHdr != previous.videoHdr ||
          lowLightBoost != previous.lowLightBoost ||
          videoStabilization != previous.videoStabilization,
      autoFocus: autoFocus != previous.autoFocus,
      frameProcessing:
          enableFrameProcessing != previous.enableFrameProcessing,
      pixelFormat: pixelFormat != previous.pixelFormat,
      samplingRate: samplingRate != previous.samplingRate,
      filter: filterShader != previous.filterShader,
    );
  }

  static String _formatKey(CameraDeviceFormat? f) => f == null
      ? ''
      : '${f.videoWidth}x${f.videoHeight}@${f.maxFps}/${f.photoWidth}x${f.photoHeight}';

  @override
  bool operator ==(Object other) =>
      other is CameraConfiguration &&
      other.deviceId == deviceId &&
      _formatKey(other.format) == _formatKey(format) &&
      other.fps == fps &&
      other.enableAudio == enableAudio &&
      other.isActive == isActive &&
      other.zoom == zoom &&
      other.exposure == exposure &&
      other.flash == flash &&
      other.torch == torch &&
      other.whiteBalanceKelvin == whiteBalanceKelvin &&
      other.videoHdr == videoHdr &&
      other.lowLightBoost == lowLightBoost &&
      other.videoStabilization == videoStabilization &&
      other.autoFocus == autoFocus &&
      other.enableFrameProcessing == enableFrameProcessing &&
      other.pixelFormat == pixelFormat &&
      other.samplingRate == samplingRate &&
      other.filterShader == filterShader;

  @override
  int get hashCode => Object.hash(
        deviceId,
        _formatKey(format),
        fps,
        enableAudio,
        isActive,
        zoom,
        exposure,
        flash,
        torch,
        whiteBalanceKelvin,
        videoHdr,
        lowLightBoost,
        videoStabilization,
        autoFocus,
        enableFrameProcessing,
        pixelFormat,
        samplingRate,
        filterShader,
      );

  /// Projects this configuration onto the FFI [CameraConfig] struct — the
  /// numeric/boolean bundle the native `configure(textureId, …)` bridge applies
  /// atomically. (Device / format / fps / audio are not part of the live struct;
  /// they go through `openCamera`.)
  CameraConfig toNativeConfig() => CameraConfig(
        zoom: zoom,
        exposure: exposure,
        flash: flash.nativeValue,
        torch: torch ? 1 : 0,
        torchLevel: torch ? 1.0 : 0.0,
        whiteBalanceKelvin: whiteBalanceKelvin,
        videoHdr: videoHdr ? 1 : 0,
        lowLightBoost: lowLightBoost ? 1 : 0,
        autoFocus: autoFocus.nativeValue,
        videoStabilization: videoStabilization.nativeValue,
        active: isActive ? 1 : 0,
        enableFrameProcessing: enableFrameProcessing ? 1 : 0,
        pixelFormat: pixelFormat.nativeValue,
        samplingRate: samplingRate,
      );
}

/// The set of fields that changed between two [CameraConfiguration]s.
///
/// [device] `true` means the session must be reopened; every other flag maps to
/// a cheap live update. Mirrors vision-camera's difference-driven, idempotent
/// "apply only what changed" reconfiguration.
class CameraConfigurationDiff {
  final bool device;
  final bool isActive;
  final bool zoom;
  final bool exposure;
  final bool flash;
  final bool torch;
  final bool whiteBalance;
  final bool videoHdr;
  final bool autoFocus;
  final bool frameProcessing;
  final bool pixelFormat;
  final bool samplingRate;
  final bool filter;

  const CameraConfigurationDiff._({
    this.device = false,
    this.isActive = false,
    this.zoom = false,
    this.exposure = false,
    this.flash = false,
    this.torch = false,
    this.whiteBalance = false,
    this.videoHdr = false,
    this.autoFocus = false,
    this.frameProcessing = false,
    this.pixelFormat = false,
    this.samplingRate = false,
    this.filter = false,
  });

  const CameraConfigurationDiff._all()
      : device = true,
        isActive = true,
        zoom = true,
        exposure = true,
        flash = true,
        torch = true,
        whiteBalance = true,
        videoHdr = true,
        autoFocus = true,
        frameProcessing = true,
        pixelFormat = true,
        samplingRate = true,
        filter = true;

  /// Whether the session needs to be torn down and reopened.
  bool get requiresReopen => device;

  /// Whether nothing changed at all.
  bool get isEmpty =>
      !device &&
      !isActive &&
      !zoom &&
      !exposure &&
      !flash &&
      !torch &&
      !whiteBalance &&
      !videoHdr &&
      !autoFocus &&
      !frameProcessing &&
      !pixelFormat &&
      !samplingRate &&
      !filter;

  @override
  String toString() {
    final changed = <String>[
      if (device) 'device',
      if (isActive) 'isActive',
      if (zoom) 'zoom',
      if (exposure) 'exposure',
      if (flash) 'flash',
      if (torch) 'torch',
      if (whiteBalance) 'whiteBalance',
      if (videoHdr) 'videoHdr',
      if (autoFocus) 'autoFocus',
      if (frameProcessing) 'frameProcessing',
      if (pixelFormat) 'pixelFormat',
      if (samplingRate) 'samplingRate',
      if (filter) 'filter',
    ];
    return 'CameraConfigurationDiff(${changed.join(', ')})';
  }
}
