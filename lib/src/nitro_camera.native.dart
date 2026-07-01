import 'package:nitro/nitro.dart';

part 'nitro_camera.g.dart';

// ---- Enums ----

/// Which physical side of the device the camera faces.
@HybridEnum()
enum CameraPosition { front, back, external }

/// The optical lens type of the camera.
@HybridEnum()
enum CameraLensType { unknown, wideAngle, ultraWideAngle, telephoto }

/// Flash / torch mode.
@HybridEnum()
enum FlashMode { off, on, auto }

/// Auto-focus behaviour.
@HybridEnum()
enum AutoFocusMode { off, continuous, locked }

/// Camera permission status.
@HybridEnum()
enum PermissionStatus { notDetermined, granted, denied, restricted }

/// Video stabilization mode applied to the capture pipeline.
@HybridEnum()
enum VideoStabilizationMode {
  off,
  standard,
  cinematic,
  cinematicExtended,
  auto,
}

/// Photo capture speed-vs-quality tradeoff.
@HybridEnum()
enum QualityPrioritization { speed, balanced, quality }

/// Kind of [CameraEvent] delivered on [NitroCamera.eventStream].
@HybridEnum()
enum CameraEventType {
  started,
  stopped,
  error,
  interruptionStarted,
  interruptionEnded,
  frameDropped,
}

/// Why the camera session was interrupted (mirrors AVFoundation reasons).
@HybridEnum()
enum InterruptionReason {
  none,
  videoDeviceNotAvailableInBackground,
  audioDeviceInUseByAnotherClient,
  videoDeviceInUseByAnotherClient,
  videoDeviceNotAvailableWithMultipleForegroundApps,
  videoDeviceNotAvailableDueToSystemPressure,
  unknown,
}

// ---- Structs ----

/// Describes a physical camera device available on the hardware.
@hybridRecord
class CameraDevice {
  final String id;
  final String name;
  final int position; // CameraPosition
  final int lensType; // CameraLensType
  final int sensorOrientation; // degrees: 0 / 90 / 180 / 270
  final double minZoom;
  final double maxZoom;
  final double neutralZoom;
  final int hasFlash; // bool as int64 (0 / 1)
  final int hasTorch; // bool as int64 (0 / 1)
  final int maxPhotoWidth;
  final int maxPhotoHeight;
  final double focalLength;
  final double aperture;

  const CameraDevice({
    required this.id,
    required this.name,
    required this.position,
    this.lensType = 0,
    required this.sensorOrientation,
    this.minZoom = 1.0,
    required this.maxZoom,
    required this.neutralZoom,
    this.hasFlash = 0,
    this.hasTorch = 0,
    required this.maxPhotoWidth,
    required this.maxPhotoHeight,
    this.focalLength = 3.5,
    this.aperture = 1.8,
  });
}

/// A raw camera frame emitted by the frame-processing stream.
/// `pixels` is a zero-copy view into the native camera buffer (BGRA / RGBA).
/// Process the frame synchronously inside the stream listener;
/// do NOT hold a reference past that point.
@HybridStruct(zeroCopy: ['pixels'])
class CameraFrame {
  final Uint8List pixels;
  final int size;
  final int width;
  final int height;
  final int timestamp; // ms since epoch
  final int orientation; // degrees: 0 / 90 / 180 / 270
  final int textureId; // identifies which camera session this frame belongs to
  final int bytesPerRow; // row stride of [pixels] (plane 0); != width*bpp when padded
  final int pixelFormat; // 0 = YUV_420 (plane 0 = luma), 1 = BGRA_8888
  final int isMirrored; // 0 / 1 (front camera)

  const CameraFrame({
    required this.pixels,
    required this.size,
    required this.width,
    required this.height,
    required this.timestamp,
    required this.orientation,
    required this.textureId,
    this.bytesPerRow = 0,
    this.pixelFormat = 1,
    this.isMirrored = 0,
  });
}

/// Result returned after a photo is captured.
@hybridRecord
class PhotoResult {
  final String path; // absolute file path
  final int width;
  final int height;
  final int fileSize; // bytes
  final int orientation; // degrees: 0 / 90 / 180 / 270
  final int isMirrored; // 0 / 1 (front-camera captures)
  final int timestamp; // ms since epoch

  const PhotoResult({
    required this.path,
    required this.width,
    required this.height,
    required this.fileSize,
    this.orientation = 0,
    this.isMirrored = 0,
    this.timestamp = 0,
  });
}

/// Result returned after a video recording is stopped.
@hybridRecord
class RecordingResult {
  final String path; // absolute file path
  final int durationMs;
  final int fileSize; // bytes

  const RecordingResult({
    required this.path,
    required this.durationMs,
    required this.fileSize,
  });
}

/// A bundle of live camera settings applied atomically to an already-open
/// session via [NitroCamera.configure]. This is the FFI struct behind the
/// declarative `CameraConfiguration` Dart API: numeric/boolean only, so it
/// crosses the boundary by value at zero serialization cost. Device / format /
/// fps / audio changes still go through [NitroCamera.openCamera] (a reopen).
@HybridStruct()
class CameraConfig {
  final double zoom;
  final double exposure; // EV bias
  final int flash; // FlashMode index
  final int torch; // 0 / 1
  final double torchLevel; // 0.0 .. 1.0 (when torch on)
  final int whiteBalanceKelvin; // 0 = auto
  final int videoHdr; // 0 / 1
  final int lowLightBoost; // 0 / 1
  final int autoFocus; // AutoFocusMode index
  final int videoStabilization; // VideoStabilizationMode index
  final int active; // 0 = paused, 1 = running
  final int enableFrameProcessing; // 0 / 1
  final int pixelFormat; // 0 = YUV_420, 1 = BGRA
  final int samplingRate; // deliver every Nth frame

  const CameraConfig({
    required this.zoom,
    required this.exposure,
    required this.flash,
    required this.torch,
    required this.torchLevel,
    required this.whiteBalanceKelvin,
    required this.videoHdr,
    required this.lowLightBoost,
    required this.autoFocus,
    required this.videoStabilization,
    required this.active,
    required this.enableFrameProcessing,
    required this.pixelFormat,
    required this.samplingRate,
  });
}

/// The configuration the native session actually applied — the read-back that
/// mirrors vision-camera's `onSessionConfigSelected`. Returned by
/// [NitroCamera.configure].
@HybridStruct()
class ResolvedConfig {
  final int width;
  final int height;
  final int fps;
  final int pixelFormat;
  final int videoHdrEnabled; // 0 / 1
  final int autoFocusSystem; // 0 = none, 1 = contrast, 2 = phase
  final int active; // 0 / 1

  const ResolvedConfig({
    required this.width,
    required this.height,
    required this.fps,
    required this.pixelFormat,
    required this.videoHdrEnabled,
    required this.autoFocusSystem,
    required this.active,
  });
}

/// Per-capture options for [NitroCamera.takePhotoWithOptions].
@HybridStruct()
class PhotoOptions {
  final int flash; // FlashMode index
  final int qualityPrioritization; // QualityPrioritization index
  final int enableShutterSound; // 0 / 1
  final int skipMetadata; // 0 / 1
  final int enableAutoRedEyeReduction; // 0 / 1

  const PhotoOptions({
    required this.flash,
    required this.qualityPrioritization,
    required this.enableShutterSound,
    required this.skipMetadata,
    required this.enableAutoRedEyeReduction,
  });
}

/// A lifecycle / error event emitted by a camera session on
/// [NitroCamera.eventStream].
@hybridRecord
class CameraEvent {
  final int type; // CameraEventType
  final int textureId; // which session (0 if not session-specific)
  final int reason; // InterruptionReason for interruption events; else 0
  final String message; // human-readable detail for `error` events

  const CameraEvent({
    required this.type,
    required this.textureId,
    this.reason = 0,
    this.message = '',
  });
}

// ---- Module ----

/// The main NitroCamera hybrid module.
///
/// Use [NitroCamera.instance] directly, or prefer the higher-level
/// [CameraController] + [CameraPreview] Dart API for widget integration.
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class NitroCamera extends HybridObject {
  static final NitroCamera instance = _NitroCameraImpl();

  // ---- Permissions ----

  /// Requests camera permission from the OS.
  /// Returns a [PermissionStatus] value.
  @nitroAsync
  Future<int> requestCameraPermission();

  /// Returns the current camera permission status without prompting.
  int getCameraPermissionStatus();

  /// Requests microphone permission from the OS.
  /// Returns a [PermissionStatus] value.
  @nitroAsync
  Future<int> requestMicrophonePermission();

  /// Returns the current microphone permission status without prompting.
  int getMicrophonePermissionStatus();

  // ---- Device enumeration ----

  @nitroAsync
  Future<String> getAvailableCameraDevicesJson();

  /// Returns a list of all available camera devices.
  List<CameraDevice> getAvailableCameraDevices();

  // Legacy low-level device accessors (kept for ABI compatibility).
  int getDeviceCount();
  CameraDevice getDevice(int index);

  // ---- Camera lifecycle ----
  //
  // [openCamera] registers a Flutter Texture and starts a camera session.
  // The returned integer is the Flutter textureId — pass it to
  //   Texture(textureId: textureId)
  // to render the live preview with GPU acceleration (zero CPU copy).

  /// Opens the camera identified by [deviceId] and starts streaming frames
  /// into a Flutter Texture. Returns the Flutter texture ID.
  ///
  /// [width] / [height] — requested preview resolution.
  /// [fps] — target frame rate (e.g. 30 or 60).
  /// [enableAudio] — 1 to capture audio for video recording, 0 otherwise.
  @nitroAsync
  Future<int> openCamera(
    String deviceId,
    int width,
    int height,
    int fps,
    int enableAudio,
  );

  @nitroAsync
  Future<void> closeCamera(int textureId);

  /// Resumes the camera preview after [stopPreview].
  void startPreview(int textureId);

  /// Pauses the camera preview without closing the session.
  void stopPreview(int textureId);

  // ---- Camera controls ----

  /// Sets the zoom level. Must be within [CameraDevice.minZoom] .. [CameraDevice.maxZoom].
  void setZoom(int textureId, double zoom);

  /// Locks focus at the normalised point ([x], [y]) where (0,0) is top-left.
  void setFocusPoint(int textureId, double x, double y);

  /// Sets the auto-focus mode. Pass an [AutoFocusMode] value.
  void setAutoFocus(int textureId, int mode);

  /// Sets exposure compensation. [value] is -1.0 (darkest) to 1.0 (brightest).
  void setExposure(int textureId, double value);

  /// Sets the flash mode for photo capture. Pass a [FlashMode] value.
  void setFlash(int textureId, int mode);

  /// Enables or disables the torch (continuous flashlight). [enabled]: 1 = on.
  void setTorch(int textureId, int enabled);

  /// Sets the white-balance colour temperature in Kelvin.
  /// Pass 0 to restore automatic white balance.
  void setWhiteBalance(int textureId, int temperature);

  /// Enables or disables HDR capture. [enabled]: 1 = on.
  void setHdr(int textureId, int enabled);

  // ---- Photo capture ----

  @nitroAsync
  Future<PhotoResult> takePhoto(int textureId);

  // ---- Video recording ----

  @nitroAsync
  Future<void> startVideoRecording(int textureId, String outputPath);

  @nitroAsync
  Future<RecordingResult> stopVideoRecording(int textureId);

  /// Pauses an active video recording without finalising the file.
  void pauseRecording(int textureId);

  /// Resumes a paused video recording.
  void resumeRecording(int textureId);

  /// Cancels the current recording and deletes the temporary file.
  void cancelRecording(int textureId);

  // ---- Frame processing ----
  //
  // Enabling frame processing delivers raw pixel data via [frameStream]
  // in addition to the GPU texture preview.
  // Disable it when not needed to save CPU / memory bandwidth.

  /// Enables or disables raw frame delivery to [frameStream].
  /// [enabled]: 1 = on, 0 = off.
  void enableFrameProcessing(int textureId, int enabled);

  /// Sets the pixel format for the [frameStream].
  /// [format]: 0 = YUV_420_888 (Planar), 1 = BGRA_8888 (Interleaved RGB).
  void setFrameFormat(int textureId, int format);

  /// Configures how many frames to skip before delivering to [frameStream].
  /// [samplingRate]: 1 = every frame, 2 = every 2nd frame, etc.
  void setSamplingRate(int textureId, int samplingRate);

  /// Updates the GPU-accelerated filter shader on the camera preview.
  /// Pass a valid GLSL Fragment Shader source.
  /// The shader should expect:
  /// - `uniform samplerExternalOES sTexture`
  /// - `varying vec2 vTextureCoord`
  void setFilterShader(int textureId, String shaderSource);

  /// Draws a persistent shape or text vector onto the camera overlay.
  /// Renders directly on the GPU using the custom pipeline.
  /// [overlayData] is a serialized binary Buffer of draw commands.
  void updateOverlay(int textureId, @zeroCopy Uint8List overlayData);

  // ---- Declarative configuration & advanced controls ----
  //
  // These mirror vision-camera's configuration-driven session model: batch a set
  // of live settings into a [CameraConfig], apply them atomically, and read back
  // what was actually selected as a [ResolvedConfig].

  /// Applies a batch of live settings to the open session [textureId] in one
  /// pass and returns what was actually applied. The declarative analogue of the
  /// individual setters above — does NOT reopen the session (device/format/fps
  /// changes must go through [openCamera]).
  @nitroAsync
  Future<ResolvedConfig> configure(int textureId, CameraConfig config);

  /// Returns the live session state (running, fps, resolution, pixelFormat) as a
  /// JSON object. Useful for diagnostics and UI read-back.
  String getSessionStateJson(int textureId);

  /// Sets the video stabilization mode. Pass a [VideoStabilizationMode] value.
  void setVideoStabilization(int textureId, int mode);

  /// Enables or disables low-light boost (night mode). [enabled]: 1 = on.
  void setLowLightBoost(int textureId, int enabled);

  /// Sets the torch brightness in 0.0..1.0 (1.0 = max). Values > 0 imply torch on.
  void setTorchLevel(int textureId, double level);

  /// Locks or unlocks auto-exposure at its current value. [locked]: 1 = locked.
  void lockExposure(int textureId, int locked);

  /// Locks or unlocks focus at its current position. [locked]: 1 = locked.
  void lockFocus(int textureId, int locked);

  /// Locks or unlocks white balance at its current gains. [locked]: 1 = locked.
  void lockWhiteBalance(int textureId, int locked);

  /// Sets the target output orientation in degrees (0 / 90 / 180 / 270).
  void setTargetOrientation(int textureId, int degrees);

  /// Captures a photo using explicit [options] (flash, quality, shutter sound).
  @nitroAsync
  Future<PhotoResult> takePhotoWithOptions(int textureId, PhotoOptions options);

  /// Captures the current preview frame as a fast JPEG snapshot (no full
  /// still-capture round-trip).
  @nitroAsync
  Future<PhotoResult> takeSnapshot(int textureId);

  /// Resets the native camera metadata caches and releases overall hardware locks.
  /// Call this to recover from serious [CAMERA_ERROR] or when hardware
  /// configuration changes (e.g. plugging in a USB camera).
  void reset();

  /// Stream of raw camera frames for custom image processing pipelines.
  /// Only active for sessions where [enableFrameProcessing] was called with 1.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frameStream;

  /// Stream of session lifecycle / error / interruption events across all open
  /// camera sessions. Buffered (oldest dropped) so events are never lost to a
  /// briefly-slow listener.
  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<CameraEvent> get eventStream;
}
