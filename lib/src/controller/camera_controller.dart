import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'package:flutter/foundation.dart';
import '../configuration/configuration.dart';
import '../models/models.dart';
import '../nitro_camera.native.dart';

export '../configuration/configuration.dart';
export '../models/models.dart';

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

  bool _isDisposed = false;
  bool _isRecording = false;
  bool _isRecordingPaused = false;

  double _zoom = 1.0;
  double _exposure = 0.0;
  FlashMode _flash = FlashMode.off;
  bool _torch = false;

  double get zoom => _zoom;
  double get exposure => _exposure;
  FlashMode get flash => _flash;
  bool get torch => _torch;

  bool get isRecording => _isRecording;
  bool get isRecordingPaused => _isRecordingPaused;

  // ---- Declarative configuration (mirrors vision-camera) ----

  CameraConfiguration? _configuration;
  ResolvedCameraConfig? _resolvedConfig;

  /// The last-applied declarative configuration (null until [initialize]).
  CameraConfiguration? get configuration => _configuration;

  /// What format negotiation actually selected — the analogue of
  /// vision-camera's `onSessionConfigSelected` read-back.
  ResolvedCameraConfig? get resolvedConfig => _resolvedConfig;

  /// Builds a [ResolvedCameraConfig]. When a native [ResolvedConfig] read-back
  /// is supplied (from `NitroCamera.configure`), its actual width/height/fps/
  /// pixelFormat/HDR/AF-system win over the Dart-side guesses.
  ResolvedCameraConfig? _resolvedFrom(CameraConfiguration c, {ResolvedConfig? native}) {
    final f = c.format;
    if (f == null) return null;
    return ResolvedCameraConfig(
      format: f,
      selectedFps: native?.fps ?? c.fps,
      videoWidth: native?.width ?? f.videoWidth,
      videoHeight: native?.height ?? f.videoHeight,
      photoWidth: f.photoWidth,
      photoHeight: f.photoHeight,
      videoHdrEnabled: native != null ? native.videoHdrEnabled != 0 : (c.videoHdr && f.supportsVideoHdr),
      pixelFormat: native != null ? PixelFormat.fromNative(native.pixelFormat) : c.pixelFormat,
      autoFocusSystem: native != null ? _afSystemFrom(native.autoFocusSystem) : f.autoFocusSystem,
    );
  }

  static AutoFocusSystem _afSystemFrom(int v) => switch (v) {
    1 => AutoFocusSystem.contrastDetection,
    2 => AutoFocusSystem.phaseDetection,
    _ => AutoFocusSystem.none,
  };

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
    return _permissionFrom(v);
  }

  /// Shorthand: request microphone permission and return the status.
  static Future<PermissionStatus> requestMicrophonePermission() async {
    final v = await NitroCamera.instance.requestMicrophonePermission();
    return _permissionFrom(v);
  }

  // An unknown status index (native/plugin version skew) is treated as denied
  // rather than throwing a RangeError — the conservative interpretation.
  static PermissionStatus _permissionFrom(int v) => (v >= 0 && v < PermissionStatus.values.length) ? PermissionStatus.values[v] : PermissionStatus.denied;

  // ---- Lifecycle ----

  /// Opens the camera and registers the Flutter texture.
  ///
  /// [width] / [height] / [fps] override the values derived from [format] when
  /// supplied (e.g. to open at a screen-matched resolution). The camera then
  /// negotiates the closest hardware-supported size natively.
  Future<void> initialize({int? width, int? height, int? fps}) async {
    final fmt = format ?? device.formats.firstOrNull;
    final w = width ?? fmt?.videoWidth ?? 1280;
    final h = height ?? fmt?.videoHeight ?? 720;
    final targetFps = fps ?? fmt?.maxFps.toInt() ?? 30;

    final tid = await NitroCamera.instance.openCamera(
      device.id,
      w,
      h,
      targetFps,
      audio ? 1 : 0,
    );
    // The native side returns 0 when the open failed (unknown device, HAL
    // rejection, ...). Treating 0 as a live session would publish a broken
    // controller — surface it as an error so callers can retry/back off.
    if (tid == 0) {
      throw DeviceException.openFailed(device.id);
    }
    _textureId = tid;
    // The requested w/h are screen-matched, not the camera's real output size —
    // read back the actual, orientation-corrected preview dimensions so the
    // preview's aspect ratio is correct (not stretched). Defensive: never let a
    // read-back hiccup abort opening.
    int aw = w, ah = h;
    try {
      final st = getSessionState();
      if (st.width > 0 && st.height > 0) {
        aw = st.width;
        ah = st.height;
      }
    } catch (_) {}
    _width = aw;
    _height = ah;
    _sensorOrientation = device.sensorOrientation;
    _isActive = true;
    _configuration = CameraConfiguration(
      deviceId: device.id,
      format: fmt,
      fps: targetFps,
      enableAudio: audio,
      isActive: true,
    );
    _resolvedConfig = _resolvedFrom(_configuration!);
    notifyListeners();
  }

  /// Applies a new declarative [CameraConfiguration], updating only what changed.
  ///
  /// A device / format / fps / audio change tears the session down and reopens
  /// it (the [textureId] changes); every other change is a cheap live update.
  /// This is the diff-driven, "apply only what changed" analogue of
  /// vision-camera's `configure()`.
  Future<void> configure(CameraConfiguration next) async {
    _requireInitialized();
    final d = next.diff(_configuration);
    if (d.isEmpty) return;

    if (d.requiresReopen) {
      final old = _textureId;
      if (old != null) await NitroCamera.instance.closeCamera(old);
      final w = next.format?.videoWidth ?? _width;
      final h = next.format?.videoHeight ?? _height;
      final tid = await NitroCamera.instance.openCamera(
        next.deviceId ?? device.id,
        w,
        h,
        next.fps,
        next.enableAudio ? 1 : 0,
      );
      if (tid == 0) {
        _textureId = null;
        throw DeviceException.openFailed(next.deviceId ?? device.id);
      }
      _textureId = tid;
      _width = w;
      _height = h;
      _isActive = true;
    }

    final cam = NitroCamera.instance;
    final tid = _textureId!;

    // Batch-apply every live setting in ONE native call and read back what the
    // session actually selected — the diff-driven analogue of vision-camera's
    // `configure()`. The filter shader is a separate (potentially large) string
    // payload, so it stays out of the numeric config struct.
    final resolved = await cam.configure(tid, next.toNativeConfig());
    if (d.filter) cam.setFilterShader(tid, next.filterShader);
    _isActive = next.isActive;

    _configuration = next;
    _resolvedConfig = _resolvedFrom(next, native: resolved) ?? _resolvedConfig;
    notifyListeners();
  }

  /// Internal use only: Initialise the controller with an already-opened texture ID.
  ///
  /// Also seeds [configuration] so a later [configure] call diffs against the
  /// current state (and applies as cheap live updates) instead of triggering a
  /// spurious reopen.
  @internal
  void initializeWithTexture(int id, int width, int height, int sensorOrientation, {int fps = 30}) {
    _textureId = id;
    _width = width;
    _height = height;
    _sensorOrientation = sensorOrientation;
    _isActive = true;
    _configuration = CameraConfiguration(
      deviceId: device.id,
      fps: fps,
      isActive: true,
    );
    _resolvedConfig = _resolvedFrom(_configuration!);
    notifyListeners();
  }

  /// True once [closeSession] (or [dispose]) has closed the native session.
  bool _sessionClosed = false;

  /// Closes the native camera session — freeing the camera **hardware** for
  /// the next open — while keeping this controller (and [textureId]) alive.
  ///
  /// A mounted `Texture` widget keeps showing the session's last rendered
  /// frame: the native side defers the Flutter texture release past the swap
  /// window. This is the first half of a freeze-frame device switch — close
  /// the old camera *before* opening the new one (two briefly-overlapping
  /// open cameras wedge constrained HALs), then call [dispose] once the new
  /// preview is on screen.
  Future<void> closeSession() async {
    if (_sessionClosed || _isDisposed) return;
    _sessionClosed = true;
    final tid = _textureId;
    if (tid != null) {
      await NitroCamera.instance.closeCamera(tid);
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    final tid = _textureId;
    _textureId = null;
    if (tid != null && !_sessionClosed) {
      _sessionClosed = true;
      await NitroCamera.instance.closeCamera(tid);
    }
    super.dispose();
  }

  // ---- Preview control ----

  void pausePreview() => setActive(false);
  void resumePreview() => setActive(true);

  // ---- Camera controls (vision_camera naming) ----
  //
  // Every setter also patches [configuration] so the declarative state stays in
  // sync with imperative calls — a later [configure] then diffs correctly.

  void _patchConfig(CameraConfiguration Function(CameraConfiguration c) fn) {
    final c = _configuration;
    if (c != null) _configuration = fn(c);
  }

  /// Zoom factor clamped to [device.minZoom] .. [device.maxZoom].
  void setZoom(double zoom) {
    _requireInitialized();
    final clamped = zoom.clamp(device.minZoom, device.maxZoom);
    NitroCamera.instance.setZoom(_textureId!, clamped);
    _zoom = clamped;
    _patchConfig((c) => c.copyWith(zoom: clamped));
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
    _patchConfig((c) => c.copyWith(autoFocus: mode));
  }

  /// Exposure bias in the range [device.minExposure] .. [device.maxExposure].
  void setExposure(double value) {
    _requireInitialized();
    NitroCamera.instance.setExposure(_textureId!, value);
    _exposure = value;
    _patchConfig((c) => c.copyWith(exposure: value));
    notifyListeners();
  }

  /// Flash mode for photo capture.
  void setFlash(FlashMode mode) {
    _requireInitialized();
    NitroCamera.instance.setFlash(_textureId!, mode.nativeValue);
    _flash = mode;
    _patchConfig((c) => c.copyWith(flash: mode));
    notifyListeners();
  }

  /// Continuous torch (flashlight) on/off.
  void setTorch({required bool enabled}) {
    _requireInitialized();
    NitroCamera.instance.setTorch(_textureId!, enabled ? 1 : 0);
    _torch = enabled;
    _patchConfig((c) => c.copyWith(torch: enabled));
    notifyListeners();
  }

  /// White balance colour temperature in Kelvin. Pass 0 to restore auto.
  void setWhiteBalance(int kelvin) {
    _requireInitialized();
    NitroCamera.instance.setWhiteBalance(_textureId!, kelvin);
    _patchConfig((c) => c.copyWith(whiteBalanceKelvin: kelvin));
  }

  /// Enables or disables HDR mode.
  void setHdr({required bool enabled}) {
    _requireInitialized();
    NitroCamera.instance.setHdr(_textureId!, enabled ? 1 : 0);
    _patchConfig((c) => c.copyWith(videoHdr: enabled));
  }

  /// Frame-stream pixel format.
  void setPixelFormat(PixelFormat format) {
    _requireInitialized();
    NitroCamera.instance.setFrameFormat(_textureId!, format.nativeValue);
    _patchConfig((c) => c.copyWith(pixelFormat: format));
  }

  /// Reads the live native session state (running / resolution / fps / pixel
  /// format) as a typed [SessionState].
  SessionState getSessionState() {
    _requireInitialized();
    return SessionState.fromJson(
      NitroCamera.instance.getSessionStateJson(_textureId!),
    );
  }

  /// Deliver every Nth frame to [frameStream] (1 = every frame).
  void setSamplingRate(int rate) {
    _requireInitialized();
    NitroCamera.instance.setSamplingRate(_textureId!, rate);
    _patchConfig((c) => c.copyWith(samplingRate: rate));
  }

  /// Video stabilization mode.
  void setVideoStabilization(VideoStabilizationMode mode) {
    _requireInitialized();
    NitroCamera.instance.setVideoStabilization(_textureId!, mode.nativeValue);
    _patchConfig((c) => c.copyWith(videoStabilization: mode));
  }

  /// Enables or disables low-light boost (night mode).
  void setLowLightBoost({required bool enabled}) {
    _requireInitialized();
    NitroCamera.instance.setLowLightBoost(_textureId!, enabled ? 1 : 0);
    _patchConfig((c) => c.copyWith(lowLightBoost: enabled));
  }

  /// Torch brightness in 0.0..1.0 (1.0 = max). Values > 0 imply torch on.
  void setTorchLevel(double level) {
    _requireInitialized();
    NitroCamera.instance.setTorchLevel(_textureId!, level.clamp(0.0, 1.0));
    _torch = level > 0;
    _patchConfig((c) => c.copyWith(torch: level > 0));
  }

  /// Locks / unlocks auto-exposure at its current value.
  void lockExposure({required bool locked}) {
    _requireInitialized();
    NitroCamera.instance.lockExposure(_textureId!, locked ? 1 : 0);
  }

  /// Locks / unlocks focus at its current position.
  void lockFocus({required bool locked}) {
    _requireInitialized();
    NitroCamera.instance.lockFocus(_textureId!, locked ? 1 : 0);
  }

  /// Locks / unlocks white balance at its current gains.
  void lockWhiteBalance({required bool locked}) {
    _requireInitialized();
    NitroCamera.instance.lockWhiteBalance(_textureId!, locked ? 1 : 0);
  }

  /// Sets the target output orientation in degrees (0 / 90 / 180 / 270).
  void setTargetOrientation(int degrees) {
    _requireInitialized();
    NitroCamera.instance.setTargetOrientation(_textureId!, degrees);
  }

  /// Enables / disables lens distortion correction (default ON where the
  /// device supports it — API 28+). vision-camera's
  /// `enableDistortionCorrection`.
  void setDistortionCorrection({required bool enabled}) {
    _requireInitialized();
    NitroCamera.instance.setDistortionCorrection(_textureId!, enabled ? 1 : 0);
  }

  /// Starts a NATIVE ML Kit detector ([NativeDetector.barcode] /
  /// [NativeDetector.face]) on this session's frames. Results arrive typed on
  /// [detections]. Requires the host app to add the matching ML Kit dependency
  /// (documented in the README).
  void startDetector(NativeDetector detector) => setNativeDetector(detector.wire);

  /// Stops the native detector.
  void stopDetector() => setNativeDetector('');

  /// Typed native-detector results for THIS session (vision-camera-style).
  Stream<DetectionResult> get detections => nativeDetections.map(DetectionResult.fromJson).where((r) => r != null).cast();

  /// Runs a NATIVE ML Kit detector on this session's frames:
  /// `"barcode"`, `"face"`, or `""` to stop.
  ///
  /// Prefer [startDetector] / [stopDetector] + the typed [detections] stream.
  void setNativeDetector(String detector) {
    _requireInitialized();
    NitroCamera.instance.setNativeDetector(_textureId!, detector);
  }

  /// Decoded native-detector results for THIS session, as parsed JSON maps
  /// (`{detector, width, height, rotation, results: [...]}`).
  ///
  /// Prefer the typed [detections] stream.
  Stream<Map<String, dynamic>> get nativeDetections => NitroCamera.instance.eventStream.where((e) => e.type == CameraEventType.detection.index && (e.textureId == _textureId || e.textureId == 0)).map((e) {
    try {
      return jsonDecode(e.message) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{'error': 'bad detection payload'};
    }
  });

  /// Camera-ID combinations that can stream CONCURRENTLY (multi-cam, API 30+).
  /// Each inner list is one combination that [initialize] can open as
  /// simultaneous [CameraController] instances. Empty when unsupported.
  static List<List<String>> getConcurrentCameraIds() {
    final json = NitroCamera.instance.getConcurrentCameraIdsJson();
    try {
      final raw = jsonDecode(json);
      return (raw as List).map((combo) => (combo as List).cast<String>()).toList();
    } catch (e) {
      // A malformed payload must not masquerade as "multi-cam unsupported"
      // (the native side reports that as a well-formed empty array).
      throw SessionException.malformedPayload('concurrent-camera-IDs', e);
    }
  }

  // ---- Photo capture ----

  /// Captures a photo. Returns the file path and metadata.
  Future<PhotoResult> takePhoto() async {
    _requireInitialized();
    return await NitroCamera.instance.takePhoto(_textureId!);
  }

  /// Captures a photo with explicit [options] (flash, quality, shutter sound…).
  Future<PhotoResult> takePhotoWithOptions(PhotoCaptureOptions options) async {
    _requireInitialized();
    return await NitroCamera.instance.takePhotoWithOptions(_textureId!, options.toNative());
  }

  /// Captures the current preview frame as a fast JPEG snapshot (no full
  /// still-capture round-trip).
  Future<PhotoResult> takeSnapshot() async {
    _requireInitialized();
    return await NitroCamera.instance.takeSnapshot(_textureId!);
  }

  // ---- Video recording (mirrors vision_camera) ----

  /// Starts recording to [outputPath].
  ///
  /// [options] controls codec / bit-rate / container / auto-stop limits and an
  /// optional GPS geotag (see [RecordingOptions]).
  Future<void> startRecording(
    String outputPath, {
    RecordingOptions? options,
  }) async {
    _requireInitialized();
    if (_isRecording) return;
    try {
      await NitroCamera.instance.startVideoRecording(
        _textureId!,
        outputPath,
        options ?? const RecordingOptions(),
      );
    } on CameraException {
      rethrow;
    } catch (e) {
      // A native recorder failure (e.g. an unsupported codec — no HEVC encoder
      // — or a bad output path) surfaces as a bare FFI error. Wrap it in the
      // typed hierarchy so callers can match on it (RecorderException) instead
      // of a raw StateError. The session is unharmed; recording just didn't start.
      throw RecorderException('recorder/start-failed', 'Failed to start recording: $e', cause: e);
    }
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

  /// Enables or disables raw frame delivery via [frameStream].
  void setFrameProcessing({required bool enabled}) {
    _requireInitialized();
    NitroCamera.instance.enableFrameProcessing(_textureId!, enabled ? 1 : 0);
    _patchConfig((c) => c.copyWith(enableFrameProcessing: enabled));
  }

  /// Enables raw frame delivery via [frameStream].
  void enableFrameProcessing() => setFrameProcessing(enabled: true);

  /// Disables raw frame delivery.
  void disableFrameProcessing() => setFrameProcessing(enabled: false);

  /// Stream of raw camera frames for **this** session (only active after
  /// [enableFrameProcessing]). Frames from other concurrently-open sessions
  /// (multi-cam, the double-buffered switch window) are filtered out.
  Stream<CameraFrame> get frameStream => NitroCamera.instance.frameStream.where((f) => f.textureId == _textureId);

  /// Typed session events (started / stopped / error / interruption) for **this**
  /// session. Mirrors vision-camera's session listeners.
  ///
  /// Events with a type index unknown to this plugin version (native/plugin
  /// version skew) are skipped rather than crashing the stream.
  Stream<CameraSessionEvent> get events => NitroCamera.instance.eventStream.where(CameraSessionEvent.isKnownType).map(CameraSessionEvent.fromNative).where((e) => e.textureId == _textureId || e.textureId == 0);

  /// Typed session events across **all** open sessions.
  static Stream<CameraSessionEvent> get allEvents => NitroCamera.instance.eventStream.where(CameraSessionEvent.isKnownType).map(CameraSessionEvent.fromNative);

  /// Typed frame-drop reasons for **this** session (vision-camera's
  /// `onFrameDropped`) — a sustained stream of these means the frame processor
  /// can't keep up (drop-latest backpressure is discarding frames).
  Stream<FrameDropReason> get frameDropReasons => events.where((e) => e.type == CameraEventType.frameDropped).map((e) => FrameDropReason.fromMessage(e.message));

  /// Device thermal-pressure changes while this session is open. Shed capture
  /// load (fps / resolution / HDR) as this climbs toward
  /// [ThermalState.critical] to avoid a HAL throttle or shutdown. Monitoring
  /// auto-starts with the session (no enable call needed).
  Stream<ThermalState> get thermalStates => CameraController.allEvents.where((e) => e.type == CameraEventType.thermalStateChanged).map((e) => ThermalState.fromLevel(e.rawReason));

  /// Updates the GPU filter shader applied to the preview.
  void setFilterShader(String glslSource) {
    _requireInitialized();
    NitroCamera.instance.setFilterShader(_textureId!, glslSource);
    _patchConfig((c) => c.copyWith(filterShader: glslSource));
  }

  // ---- Internal ----

  void _requireInitialized() {
    if (!isInitialized || _isDisposed) {
      throw SessionException.notInitialized();
    }
  }
}
