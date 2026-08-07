import 'dart:async';
import 'dart:typed_data';

import 'package:nitro_camera/src/nitro_camera.native.dart';

/// One recorded call against [FakeNitroCamera].
class NativeCall {
  const NativeCall(this.name, [this.args = const []]);

  final String name;
  final List<Object?> args;

  @override
  String toString() => args.isEmpty ? '$name()' : '$name(${args.join(', ')})';
}

/// A scriptable stand-in for the native bridge.
///
/// [CameraController] and [CameraView] talk to `NitroCamera` for every piece of
/// their behaviour, so without this the entire controller/widget layer is
/// untestable off-device — which is exactly why both were at 0% coverage.
/// Injected via the `native:` seam that [OrientationManager] already
/// established.
///
/// Three capabilities tests need:
///  * **Observe** — every call lands in [calls] in order, so "did the setter
///    reach native, with the clamped value?" is answerable.
///  * **Script** — return values are fields, and any method can be made to
///    throw via [failWith], to drive error paths.
///  * **Drive** — [emitEvent] / [emitFrame] push through the real broadcast
///    streams the controller subscribes to.
class FakeNitroCamera extends NitroCamera {
  final List<NativeCall> calls = <NativeCall>[];

  // ---- Scripted returns ----

  /// Texture id handed back by `openCamera`. 0 means "open failed" to the
  /// controller, which is the trigger for `DeviceException.openFailed`.
  int openCameraResult = 7;
  int cameraPermissionStatus = 1;
  int microphonePermissionStatus = 1;
  int requestCameraPermissionResult = 1;
  int requestMicrophonePermissionResult = 1;
  String availableCameraDevicesJson = '[]';
  String concurrentCameraIdsJson = '[]';
  String sessionStateJson =
      '{"running":true,"width":1920,"height":1080,"fps":30,"pixelFormat":0}';
  List<CameraDevice> devices = const <CameraDevice>[];

  PhotoResult photoResult = const PhotoResult(
    path: '/tmp/fake.jpg',
    width: 1920,
    height: 1080,
    fileSize: 1024,
    orientation: 0,
    isMirrored: 0,
    timestamp: 0,
  );

  RecordingResult recordingResult = const RecordingResult(
    path: '/tmp/fake.mp4',
    durationMs: 1000,
    fileSize: 2048,
    width: 1920,
    height: 1080,
    codec: 0,
    fileType: 0,
    finishedReason: 0,
  );

  ResolvedConfig resolvedConfig = const ResolvedConfig(
    width: 1920,
    height: 1080,
    fps: 30,
    pixelFormat: 0,
    videoHdrEnabled: 0,
    autoFocusSystem: 2,
    active: 1,
  );

  /// Method names scripted to throw, and what they throw.
  final Map<String, Object> _failures = <String, Object>{};

  /// Makes [method] throw [error] on its next and every subsequent call.
  void failWith(String method, Object error) => _failures[method] = error;

  /// Clears a previously scripted failure.
  void clearFailure(String method) => _failures.remove(method);

  final StreamController<CameraFrame> _frames =
      StreamController<CameraFrame>.broadcast();
  final StreamController<CameraEvent> _events =
      StreamController<CameraEvent>.broadcast();

  @override
  Stream<CameraFrame> get frameStream => _frames.stream;

  @override
  Stream<CameraEvent> get eventStream => _events.stream;

  // ---- Test drivers ----

  void emitEvent(
    int type, {
    int textureId = 0,
    int reason = 0,
    String message = '',
  }) => _events.add(
    CameraEvent(
      type: type,
      textureId: textureId,
      reason: reason,
      message: message,
    ),
  );

  void emitFrame({
    int textureId = 7,
    int width = 4,
    int height = 4,
    int pixelFormat = 0,
    int isMirrored = 0,
    int timestamp = 0,
    Uint8List? pixels,
  }) {
    final px = pixels ?? Uint8List(width * height);
    _frames.add(
      CameraFrame(
        pixels: px,
        size: px.length,
        width: width,
        height: height,
        timestamp: timestamp,
        orientation: 0,
        textureId: textureId,
        bytesPerRow: width,
        pixelFormat: pixelFormat,
        isMirrored: isMirrored,
      ),
    );
  }

  Future<void> close() async {
    await _frames.close();
    await _events.close();
  }

  /// Names of every recorded call, in order — the usual assertion target.
  List<String> get callNames => calls.map((c) => c.name).toList();

  /// Arguments of the last call to [name], or null when never called.
  List<Object?>? argsOf(String name) {
    for (final c in calls.reversed) {
      if (c.name == name) return c.args;
    }
    return null;
  }

  bool called(String name) => calls.any((c) => c.name == name);

  void clear() => calls.clear();

  T _rec<T>(String name, List<Object?> args, T result) {
    calls.add(NativeCall(name, args));
    final failure = _failures[name];
    if (failure != null) throw failure;
    return result;
  }

  // ---- Permissions ----

  @override
  Future<int> requestCameraPermission() async =>
      _rec('requestCameraPermission', const [], requestCameraPermissionResult);

  @override
  int getCameraPermissionStatus() =>
      _rec('getCameraPermissionStatus', const [], cameraPermissionStatus);

  @override
  Future<int> requestMicrophonePermission() async => _rec(
    'requestMicrophonePermission',
    const [],
    requestMicrophonePermissionResult,
  );

  @override
  int getMicrophonePermissionStatus() => _rec(
    'getMicrophonePermissionStatus',
    const [],
    microphonePermissionStatus,
  );

  // ---- Device enumeration ----

  @override
  Future<String> getAvailableCameraDevicesJson() async => _rec(
    'getAvailableCameraDevicesJson',
    const [],
    availableCameraDevicesJson,
  );

  @override
  List<CameraDevice> getAvailableCameraDevices() =>
      _rec('getAvailableCameraDevices', const [], devices);

  @override
  int getDeviceCount() => _rec('getDeviceCount', const [], devices.length);

  @override
  CameraDevice getDevice(int index) =>
      _rec('getDevice', [index], devices[index]);

  // ---- Lifecycle ----

  @override
  Future<int> openCamera(
    String deviceId,
    int width,
    int height,
    int fps,
    int enableAudio,
  ) async => _rec('openCamera', [
    deviceId,
    width,
    height,
    fps,
    enableAudio,
  ], openCameraResult);

  @override
  Future<void> closeCamera(int textureId) async =>
      _rec('closeCamera', [textureId], null);

  @override
  void startPreview(int textureId) => _rec('startPreview', [textureId], null);

  @override
  void stopPreview(int textureId) => _rec('stopPreview', [textureId], null);

  // ---- Controls ----

  @override
  void setZoom(int textureId, double zoom) =>
      _rec('setZoom', [textureId, zoom], null);

  @override
  void setFocusPoint(int textureId, double x, double y) =>
      _rec('setFocusPoint', [textureId, x, y], null);

  @override
  void setAutoFocus(int textureId, int mode) =>
      _rec('setAutoFocus', [textureId, mode], null);

  @override
  void setExposure(int textureId, double value) =>
      _rec('setExposure', [textureId, value], null);

  @override
  void setFlash(int textureId, int mode) =>
      _rec('setFlash', [textureId, mode], null);

  @override
  void setTorch(int textureId, int enabled) =>
      _rec('setTorch', [textureId, enabled], null);

  @override
  void setWhiteBalance(int textureId, int temperature) =>
      _rec('setWhiteBalance', [textureId, temperature], null);

  @override
  void setHdr(int textureId, int enabled) =>
      _rec('setHdr', [textureId, enabled], null);

  @override
  void setVideoStabilization(int textureId, int mode) =>
      _rec('setVideoStabilization', [textureId, mode], null);

  @override
  void setLowLightBoost(int textureId, int enabled) =>
      _rec('setLowLightBoost', [textureId, enabled], null);

  @override
  void setTorchLevel(int textureId, double level) =>
      _rec('setTorchLevel', [textureId, level], null);

  @override
  void lockExposure(int textureId, int locked) =>
      _rec('lockExposure', [textureId, locked], null);

  @override
  void lockFocus(int textureId, int locked) =>
      _rec('lockFocus', [textureId, locked], null);

  @override
  void lockWhiteBalance(int textureId, int locked) =>
      _rec('lockWhiteBalance', [textureId, locked], null);

  @override
  void setTargetOrientation(int textureId, int degrees) =>
      _rec('setTargetOrientation', [textureId, degrees], null);

  @override
  void setDistortionCorrection(int textureId, int enabled) =>
      _rec('setDistortionCorrection', [textureId, enabled], null);

  // ---- Capture ----

  @override
  Future<PhotoResult> takePhoto(int textureId) async =>
      _rec('takePhoto', [textureId], photoResult);

  @override
  Future<PhotoResult> takePhotoWithOptions(
    int textureId,
    PhotoOptions options,
  ) async => _rec('takePhotoWithOptions', [textureId, options], photoResult);

  @override
  Future<PhotoResult> takeSnapshot(int textureId) async =>
      _rec('takeSnapshot', [textureId], photoResult);

  // ---- Recording ----

  @override
  Future<void> startVideoRecording(
    int textureId,
    String outputPath,
    RecordingOptions options,
  ) async => _rec('startVideoRecording', [textureId, outputPath, options], null);

  @override
  Future<RecordingResult> stopVideoRecording(int textureId) async =>
      _rec('stopVideoRecording', [textureId], recordingResult);

  @override
  void pauseRecording(int textureId) =>
      _rec('pauseRecording', [textureId], null);

  @override
  void resumeRecording(int textureId) =>
      _rec('resumeRecording', [textureId], null);

  @override
  void cancelRecording(int textureId) =>
      _rec('cancelRecording', [textureId], null);

  // ---- Frames / analysis ----

  @override
  void enableFrameProcessing(int textureId, int enabled) =>
      _rec('enableFrameProcessing', [textureId, enabled], null);

  @override
  void setFrameFormat(int textureId, int format) =>
      _rec('setFrameFormat', [textureId, format], null);

  @override
  void setSamplingRate(int textureId, int samplingRate) =>
      _rec('setSamplingRate', [textureId, samplingRate], null);

  @override
  void setFilterShader(int textureId, String shaderSource) =>
      _rec('setFilterShader', [textureId, shaderSource], null);

  @override
  void updateOverlay(int textureId, Uint8List overlayData) =>
      _rec('updateOverlay', [textureId, overlayData], null);

  @override
  void setNativeDetector(int textureId, String detector) =>
      _rec('setNativeDetector', [textureId, detector], null);

  // ---- Session ----

  @override
  Future<ResolvedConfig> configure(int textureId, CameraConfig config) async =>
      _rec('configure', [textureId, config], resolvedConfig);

  @override
  String getSessionStateJson(int textureId) =>
      _rec('getSessionStateJson', [textureId], sessionStateJson);

  @override
  String getConcurrentCameraIdsJson() =>
      _rec('getConcurrentCameraIdsJson', const [], concurrentCameraIdsJson);

  @override
  void enableOrientationEvents(int enabled) =>
      _rec('enableOrientationEvents', [enabled], null);

  @override
  void enableDeviceAvailabilityEvents(int enabled) =>
      _rec('enableDeviceAvailabilityEvents', [enabled], null);

  @override
  void reset() => _rec('reset', const [], null);
}
