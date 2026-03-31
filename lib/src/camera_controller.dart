import 'dart:async';
import 'package:flutter/foundation.dart';
import 'camera_device.dart';
import 'nitro_camera.native.dart';

export 'camera_device.dart';

/// High-level controller that mirrors the vision_camera API surface.
///
/// ## Quick start
/// ```dart
/// // 1. Get devices (like Camera.getAvailableCameraDevices in vision_camera)
/// final devices = await CameraController.getAvailableCameraDevices();
/// final back = devices.firstWhere((d) => d.isBackCamera);
///
/// // 2. Pick a format (optional — defaults to the best available)
/// final format = back.formats.first;
///
/// // 3. Create and initialise
/// final controller = CameraController(device: back, format: format);
/// await controller.initialize();
///
/// // 4. Render
/// CameraPreview(controller: controller)
/// ```
class CameraController extends ChangeNotifier {
  /// The camera device to open.
  final CameraDeviceInfo device;

  /// The capture format to use. Defaults to the first format in [device.formats].
  final CameraDeviceFormat? format;

  /// Whether to capture audio during video recording.
  final bool audio;

  /// Whether the preview/camera session is active.
  ///
  /// Setting this to `false` pauses streaming (equivalent to [NitroCamera.stopPreview]).
  /// Defaults to `true` after [initialize].
  bool get isActive => _isActive;
  bool _isActive = false;

  /// Set [isActive] programmatically — starts or stops the preview stream.
  void setActive(bool active) {
    _requireInitialized();
    if (active == _isActive) return;
    if (active) {
      NitroCamera.instance.startPreview(_textureId!);
    } else {
      NitroCamera.instance.stopPreview(_textureId!);
    }
    _isActive = active;
    notifyListeners();
  }

  CameraController({
    required this.device,
    this.format,
    this.audio = false,
  });

  // ---- State ----

  int? _textureId;
  int _width = 1280;
  int _height = 720;
  int _sensorOrientation = 90;

  /// The Flutter texture ID. Pass this to `Texture(textureId: controller.textureId!)`.
  int? get textureId => _textureId;

  /// True once [initialize] has completed successfully.
  bool get isInitialized => _textureId != null;

  /// The width of the camera resolution.
  int get width => _width;

  /// The height of the camera resolution.
  int get height => _height;

  /// The physical orientation of the camera sensor (90/270 for portrait).
  int get sensorOrientation => _sensorOrientation;

  bool _isDisposed   = false;
  bool _isRecording  = false;
  bool _isRecordingPaused = false;

  double _zoom     = 1.0;
  double _exposure = 0.0;
  FlashMode _flash = FlashMode.off;
  bool _torch      = false;

  double    get zoom     => _zoom;
  double    get exposure => _exposure;
  FlashMode get flash    => _flash;
  bool      get torch    => _torch;

  bool get isRecording       => _isRecording;
  bool get isRecordingPaused => _isRecordingPaused;

  // ---- Static device enumeration (mirrors Camera.getAvailableCameraDevices) ----

  /// Returns all available camera devices, each with their supported formats.
  ///
  /// This is the vision_camera equivalent of `Camera.getAvailableCameraDevices()`.
  static Future<List<CameraDeviceInfo>> getAvailableCameraDevices() async {
    final json = await NitroCamera.instance.getAvailableCameraDevicesJson();
    return CameraDeviceInfo.listFromJson(json);
  }

  /// Shorthand: request camera permission and return the status.
  static Future<PermissionStatus> requestCameraPermission() async {
    final v = await NitroCamera.instance.requestCameraPermission();
    return PermissionStatus.values[v];
  }

  /// Shorthand: request microphone permission and return the status.
  static Future<PermissionStatus> requestMicrophonePermission() async {
    final v = await NitroCamera.instance.requestMicrophonePermission();
    return PermissionStatus.values[v];
  }

  // ---- Lifecycle ----

  /// Opens the camera and registers the Flutter texture.
  Future<void> initialize() async {
    final fmt = format ?? device.formats.firstOrNull;
    final w = fmt?.videoWidth ?? 1280;
    final h = fmt?.videoHeight ?? 720;
    final fps = fmt?.maxFps.toInt() ?? 30;

    _textureId = await NitroCamera.instance.openCamera(
      device.id,
      w,
      h,
      fps,
      audio ? 1 : 0,
    );
    _width = w;
    _height = h;
    _sensorOrientation = device.sensorOrientation;
    _isActive = true;
    notifyListeners();
  }

  /// Internal use only: Initialise the controller with an already-opened texture ID.
  void initializeWithTexture(int id, int width, int height, int sensorOrientation) {
    _textureId = id;
    _width = width;
    _height = height;
    _sensorOrientation = sensorOrientation;
    _isActive = true;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    final tid = _textureId;
    if (tid != null) {
      await NitroCamera.instance.closeCamera(tid);
      _textureId = null;
    }
    super.dispose();
  }

  // ---- Preview control ----

  void pausePreview() => setActive(false);
  void resumePreview() => setActive(true);

  // ---- Camera controls (vision_camera naming) ----

  /// Zoom factor clamped to [device.minZoom] .. [device.maxZoom].
  void setZoom(double zoom) {
    _requireInitialized();
    final clamped = zoom.clamp(device.minZoom, device.maxZoom);
    NitroCamera.instance.setZoom(_textureId!, clamped);
    _zoom = clamped;
    notifyListeners();
  }

  /// Focus at the normalised coordinates ([x], [y]) in range 0.0–1.0.
  /// Mirrors `camera.focus(point)` in vision_camera.
  void focus(double x, double y) {
    _requireInitialized();
    NitroCamera.instance.setFocusPoint(_textureId!, x, y);
  }

  /// Sets the auto-focus mode.
  void setAutoFocus(AutoFocusMode mode) {
    _requireInitialized();
    NitroCamera.instance.setAutoFocus(_textureId!, mode.nativeValue);
  }

  /// Exposure bias in the range [device.minExposure] .. [device.maxExposure].
  void setExposure(double value) {
    _requireInitialized();
    NitroCamera.instance.setExposure(_textureId!, value);
    _exposure = value;
    notifyListeners();
  }

  /// Flash mode for photo capture.
  void setFlash(FlashMode mode) {
    _requireInitialized();
    NitroCamera.instance.setFlash(_textureId!, mode.nativeValue);
    _flash = mode;
    notifyListeners();
  }

  /// Continuous torch (flashlight) on/off.
  void setTorch({required bool enabled}) {
    _requireInitialized();
    NitroCamera.instance.setTorch(_textureId!, enabled ? 1 : 0);
    _torch = enabled;
    notifyListeners();
  }

  /// White balance colour temperature in Kelvin. Pass 0 to restore auto.
  void setWhiteBalance(int kelvin) {
    _requireInitialized();
    NitroCamera.instance.setWhiteBalance(_textureId!, kelvin);
  }

  /// Enables or disables HDR mode.
  void setHdr({required bool enabled}) {
    _requireInitialized();
    NitroCamera.instance.setHdr(_textureId!, enabled ? 1 : 0);
  }

  // ---- Photo capture ----

  /// Captures a photo. Returns the file path and metadata.
  Future<PhotoResult> takePhoto() async {
    _requireInitialized();
    return await NitroCamera.instance.takePhoto(_textureId!);
  }

  // ---- Video recording (mirrors vision_camera) ----

  /// Starts recording to [outputPath].
  Future<void> startRecording(String outputPath) async {
    _requireInitialized();
    if (_isRecording) return;
    await NitroCamera.instance.startVideoRecording(_textureId!, outputPath);
    _isRecording = true;
    _isRecordingPaused = false;
    notifyListeners();
  }

  /// Pauses an active recording without finalising the file.
  void pauseRecording() {
    _requireInitialized();
    if (!_isRecording || _isRecordingPaused) return;
    NitroCamera.instance.pauseRecording(_textureId!);
    _isRecordingPaused = true;
    notifyListeners();
  }

  /// Resumes a paused recording.
  void resumeRecording() {
    _requireInitialized();
    if (!_isRecording || !_isRecordingPaused) return;
    NitroCamera.instance.resumeRecording(_textureId!);
    _isRecordingPaused = false;
    notifyListeners();
  }

  /// Stops and finalises the recording. Returns the file path and metadata.
  Future<RecordingResult> stopRecording() async {
    _requireInitialized();
    final result = await NitroCamera.instance.stopVideoRecording(_textureId!);
    _isRecording = false;
    _isRecordingPaused = false;
    notifyListeners();
    return result;
  }

  /// Cancels the recording and deletes the temporary file.
  void cancelRecording() {
    _requireInitialized();
    if (!_isRecording) return;
    NitroCamera.instance.cancelRecording(_textureId!);
    _isRecording = false;
    _isRecordingPaused = false;
    notifyListeners();
  }

  // ---- Frame processing ----

  /// Enables raw frame delivery via [frameStream].
  void enableFrameProcessing() {
    _requireInitialized();
    NitroCamera.instance.enableFrameProcessing(_textureId!, 1);
  }

  /// Disables raw frame delivery.
  void disableFrameProcessing() {
    _requireInitialized();
    NitroCamera.instance.enableFrameProcessing(_textureId!, 0);
  }

  /// Stream of raw camera frames (only active after [enableFrameProcessing]).
  Stream<CameraFrame> get frameStream => NitroCamera.instance.frameStream;

  /// Updates the GPU filter shader applied to the preview.
  void setFilterShader(String glslSource) {
    _requireInitialized();
    NitroCamera.instance.setFilterShader(_textureId!, glslSource);
  }

  // ---- Internal ----

  void _requireInitialized() {
    if (!isInitialized || _isDisposed) {
      throw StateError('CameraController is not initialised. Call initialize() first.');
    }
  }
}
