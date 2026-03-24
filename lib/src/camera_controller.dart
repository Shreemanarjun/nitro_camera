import 'dart:async';
import 'package:flutter/foundation.dart';
import 'nitro_camera.native.dart';

/// High-level Dart wrapper around [NitroCamera].
///
/// Usage:
/// ```dart
/// final controller = CameraController(deviceId: device.id);
/// await controller.initialize();
/// // Use Texture(textureId: controller.textureId!) in the widget tree.
/// await controller.dispose();
/// ```
class CameraController extends ChangeNotifier {
  /// The camera device ID to open (from [NitroCamera.getDevice]).
  final String deviceId;

  /// Requested preview width. Defaults to 1280.
  final int previewWidth;

  /// Requested preview height. Defaults to 720.
  final int previewHeight;

  /// Requested frame rate. Defaults to 30.
  final int fps;

  /// Whether to capture audio when recording video. Defaults to false.
  final bool enableAudio;

  CameraController({
    required this.deviceId,
    this.previewWidth  = 1280,
    this.previewHeight = 720,
    this.fps           = 30,
    this.enableAudio   = false,
  });

  // ---- State ----

  /// The Flutter texture ID registered by the native camera session.
  /// Pass this to `Texture(textureId: textureId!)` to display the preview.
  int? textureId;

  /// True once [initialize] has completed successfully.
  bool get isInitialized => textureId != null;

  bool _isDisposed      = false;
  bool _isRecording     = false;
  bool _previewRunning  = false;
  bool _frameProcessing = false;

  double _zoom      = 1.0;
  double _exposure  = 0.0;
  FlashMode _flash  = FlashMode.off;
  bool   _torch     = false;

  double get zoom     => _zoom;
  double get exposure => _exposure;
  FlashMode get flash => _flash;
  bool   get torch    => _torch;

  bool get isRecording     => _isRecording;
  bool get isPreviewRunning => _previewRunning;

  // ---- Lifecycle ----

  /// Opens the camera and registers the Flutter texture.
  /// Must be called before using the controller.
  Future<void> initialize() async {
    textureId = await NitroCamera.instance.openCamera(
      deviceId,
      previewWidth,
      previewHeight,
      fps,
      enableAudio ? 1 : 0,
    );
    _previewRunning = true;
    notifyListeners();
  }

  /// Releases all native resources.
  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    if (textureId != null) {
      await NitroCamera.instance.closeCamera(textureId!);
    }
    super.dispose();
  }

  // ---- Preview control ----

  Future<void> pausePreview() async {
    _requireInitialized();
    await NitroCamera.instance.stopPreview(textureId!);
    _previewRunning = false;
    notifyListeners();
  }

  Future<void> resumePreview() async {
    _requireInitialized();
    await NitroCamera.instance.startPreview(textureId!);
    _previewRunning = true;
    notifyListeners();
  }

  // ---- Camera controls ----

  /// Sets the zoom level in the range [[CameraDevice.minZoom], [CameraDevice.maxZoom]].
  Future<void> setZoom(double zoom) async {
    _requireInitialized();
    await NitroCamera.instance.setZoom(textureId!, zoom);
    _zoom = zoom;
    notifyListeners();
  }

  /// Moves the focus point to the normalised coordinates ([x], [y]), range 0.0–1.0.
  Future<void> setFocusPoint(double x, double y) async {
    _requireInitialized();
    await NitroCamera.instance.setFocusPoint(textureId!, x, y);
  }

  /// Sets the auto-focus mode.
  Future<void> setAutoFocus(AutoFocusMode mode) async {
    _requireInitialized();
    await NitroCamera.instance.setAutoFocus(textureId!, mode.nativeValue);
  }

  /// Sets the exposure compensation. [value] is -1.0 (darkest) to 1.0 (brightest).
  Future<void> setExposure(double value) async {
    _requireInitialized();
    await NitroCamera.instance.setExposure(textureId!, value);
    _exposure = value;
    notifyListeners();
  }

  /// Sets the flash mode for photo capture.
  Future<void> setFlash(FlashMode mode) async {
    _requireInitialized();
    await NitroCamera.instance.setFlash(textureId!, mode.nativeValue);
    _flash = mode;
    notifyListeners();
  }

  /// Enables or disables the torch (continuous flashlight).
  Future<void> setTorch({required bool enabled}) async {
    _requireInitialized();
    await NitroCamera.instance.setTorch(textureId!, enabled ? 1 : 0);
    _torch = enabled;
    notifyListeners();
  }

  /// Sets the white balance temperature in Kelvin. Pass 0 to restore auto.
  Future<void> setWhiteBalance(int temperature) async {
    _requireInitialized();
    await NitroCamera.instance.setWhiteBalance(textureId!, temperature);
  }

  /// Enables or disables HDR mode.
  Future<void> setHdr({required bool enabled}) async {
    _requireInitialized();
    await NitroCamera.instance.setHdr(textureId!, enabled ? 1 : 0);
  }

  // ---- Photo capture ----

  /// Captures a photo. Returns the file path and metadata.
  Future<PhotoResult> takePhoto() async {
    _requireInitialized();
    return NitroCamera.instance.takePhoto(textureId!);
  }

  // ---- Video recording ----

  /// Starts video recording to [outputPath].
  Future<void> startVideoRecording(String outputPath) async {
    _requireInitialized();
    if (_isRecording) return;
    await NitroCamera.instance.startVideoRecording(textureId!, outputPath);
    _isRecording = true;
    notifyListeners();
  }

  /// Stops video recording and returns the result.
  Future<RecordingResult> stopVideoRecording() async {
    _requireInitialized();
    final result = await NitroCamera.instance.stopVideoRecording(textureId!);
    _isRecording = false;
    notifyListeners();
    return result;
  }

  // ---- Frame processing ----

  /// Enables raw frame delivery via [frameStream].
  Future<void> enableFrameProcessing() async {
    _requireInitialized();
    if (_frameProcessing) return;
    await NitroCamera.instance.enableFrameProcessing(textureId!, 1);
    _frameProcessing = true;
  }

  /// Disables raw frame delivery.
  Future<void> disableFrameProcessing() async {
    _requireInitialized();
    if (!_frameProcessing) return;
    await NitroCamera.instance.enableFrameProcessing(textureId!, 0);
    _frameProcessing = false;
  }

  /// Stream of raw camera frames (only active after [enableFrameProcessing]).
  Stream<CameraFrame> get frameStream => NitroCamera.instance.frameStream;

  // ---- Internal ----

  void _requireInitialized() {
    if (!isInitialized || _isDisposed) {
      throw StateError('CameraController is not initialised. Call initialize() first.');
    }
  }
}
