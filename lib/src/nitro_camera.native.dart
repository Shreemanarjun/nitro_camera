import 'dart:typed_data';

import 'package:nitro/nitro.dart';

part 'nitro_camera.g.dart';

// ---- Enums ----

/// Which physical side of the device the camera faces.
@HybridEnum()
enum CameraPosition {
  front,
  back,
  external,
}

/// The optical lens type of the camera.
@HybridEnum()
enum CameraLensType {
  unknown,
  wideAngle,
  ultraWideAngle,
  telephoto,
}

/// Flash / torch mode.
@HybridEnum()
enum FlashMode {
  off,
  on,
  auto,
}

/// Auto-focus behaviour.
@HybridEnum()
enum AutoFocusMode {
  off,
  continuous,
  locked,
}

/// Camera permission status.
@HybridEnum()
enum PermissionStatus {
  notDetermined,
  granted,
  denied,
  restricted,
}

// ---- Structs ----

/// Describes a physical camera device available on the hardware.
@HybridStruct(packed: true)
class CameraDevice {
  final String id;
  final String name;
  final int position;          // CameraPosition
  final int lensType;          // CameraLensType
  final int sensorOrientation; // degrees: 0 / 90 / 180 / 270
  final double minZoom;
  final double maxZoom;
  final double neutralZoom;
  final int hasFlash;          // bool as int64 (0 / 1)
  final int hasTorch;          // bool as int64 (0 / 1)
  final int maxPhotoWidth;
  final int maxPhotoHeight;

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
  final int timestamp;    // ms since epoch
  final int orientation;  // degrees: 0 / 90 / 180 / 270
  final int textureId;    // identifies which camera session this frame belongs to

  const CameraFrame({
    required this.pixels,
    required this.size,
    required this.width,
    required this.height,
    required this.timestamp,
    required this.orientation,
    required this.textureId,
  });
}

/// Result returned after a photo is captured.
@HybridStruct(packed: true)
class PhotoResult {
  final String path;      // absolute file path
  final int width;
  final int height;
  final int fileSize;     // bytes

  const PhotoResult({
    required this.path,
    required this.width,
    required this.height,
    required this.fileSize,
  });
}

/// Result returned after a video recording is stopped.
@HybridStruct(packed: true)
class RecordingResult {
  final String path;      // absolute file path
  final int durationMs;
  final int fileSize;     // bytes

  const RecordingResult({
    required this.path,
    required this.durationMs,
    required this.fileSize,
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
  @nitroAsync
  Future<int> getCameraPermissionStatus();

  // ---- Device enumeration ----

  /// Returns the number of physical camera devices.
  @nitroAsync
  Future<int> getDeviceCount();

  /// Returns info about the camera at [index].
  @nitroAsync
  Future<CameraDevice> getDevice(int index);

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

  /// Stops the camera session and unregisters the Flutter texture.
  @nitroAsync
  Future<void> closeCamera(int textureId);

  /// Resumes the camera preview after [stopPreview].
  @nitroAsync
  Future<void> startPreview(int textureId);

  /// Pauses the camera preview without closing the session.
  @nitroAsync
  Future<void> stopPreview(int textureId);

  // ---- Camera controls ----

  /// Sets the zoom level. Must be within [CameraDevice.minZoom] .. [CameraDevice.maxZoom].
  @nitroAsync
  Future<void> setZoom(int textureId, double zoom);

  /// Locks focus at the normalised point ([x], [y]) where (0,0) is top-left.
  @nitroAsync
  Future<void> setFocusPoint(int textureId, double x, double y);

  /// Sets the auto-focus mode. Pass an [AutoFocusMode] value.
  @nitroAsync
  Future<void> setAutoFocus(int textureId, int mode);

  /// Sets exposure compensation. [value] is -1.0 (darkest) to 1.0 (brightest).
  @nitroAsync
  Future<void> setExposure(int textureId, double value);

  /// Sets the flash mode for photo capture. Pass a [FlashMode] value.
  @nitroAsync
  Future<void> setFlash(int textureId, int mode);

  /// Enables or disables the torch (continuous flashlight). [enabled]: 1 = on.
  @nitroAsync
  Future<void> setTorch(int textureId, int enabled);

  /// Sets the white-balance colour temperature in Kelvin.
  /// Pass 0 to restore automatic white balance.
  @nitroAsync
  Future<void> setWhiteBalance(int textureId, int temperature);

  /// Enables or disables HDR capture. [enabled]: 1 = on.
  @nitroAsync
  Future<void> setHdr(int textureId, int enabled);

  // ---- Photo capture ----

  /// Captures a still photo and saves it to the app's temp directory.
  @nitroAsync
  Future<PhotoResult> takePhoto(int textureId);

  // ---- Video recording ----

  /// Starts recording video to [outputPath] (must be a writable file path).
  @nitroAsync
  Future<void> startVideoRecording(int textureId, String outputPath);

  /// Stops the current recording and finalises the file.
  @nitroAsync
  Future<RecordingResult> stopVideoRecording(int textureId);

  // ---- Frame processing ----
  //
  // Enabling frame processing delivers raw pixel data via [frameStream]
  // in addition to the GPU texture preview.
  // Disable it when not needed to save CPU / memory bandwidth.

  /// Enables or disables raw frame delivery to [frameStream].
  /// [enabled]: 1 = on, 0 = off.
  @nitroAsync
  Future<void> enableFrameProcessing(int textureId, int enabled);

  /// Stream of raw camera frames for custom image processing pipelines.
  /// Only active for sessions where [enableFrameProcessing] was called with 1.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frameStream;
}
