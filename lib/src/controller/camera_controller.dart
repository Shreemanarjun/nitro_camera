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
      _native.startPreview(_textureId!);
    } else {
      _native.stopPreview(_textureId!);
    }
    _isActive = active;
    notifyListeners();
  }

  /// The native bridge this controller drives.
  ///
  /// Defaults to the process-wide [NitroCamera.instance]; tests substitute a
  /// fake so controller behaviour can be exercised without a camera. Mirrors
  /// the seam [OrientationManager] already exposes.
  final NitroCamera _native;

  CameraController({
    required this.device,
    this.format,
    this.audio = false,
    NitroCamera? native,
  }) : _native = native ?? NitroCamera.instance;

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
  /// pixelFormat/HDR/AF-system win over the Dart-side guesses. Without a
  /// format, a live [session] read-back is the only source of truth.
  ResolvedCameraConfig? _resolvedFrom(CameraConfiguration c, {ResolvedConfig? native, SessionState? session}) {
    final f = c.format;
    if (f == null) {
      if (session == null || session.width <= 0) return null;
      return ResolvedCameraConfig(
        format: null,
        selectedFps: session.fps > 0 ? session.fps : c.fps,
        videoWidth: session.width,
        videoHeight: session.height,
        photoWidth: 0,
        photoHeight: 0,
        videoHdrEnabled: false,
        pixelFormat: session.pixelFormat,
        autoFocusSystem: AutoFocusSystem.none,
      );
    }
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
  static Future<List<CameraDeviceInfo>> getAvailableCameraDevices({
    NitroCamera? native,
  }) async {
    final json =
        await (native ?? NitroCamera.instance).getAvailableCameraDevicesJson();
    return CameraDeviceInfo.listFromJson(json);
  }

  /// Shorthand: request camera permission and return the status.
  static Future<PermissionStatus> requestCameraPermission({
    NitroCamera? native,
  }) async {
    final v = await (native ?? NitroCamera.instance).requestCameraPermission();
    return _permissionFrom(v);
  }

  /// Shorthand: request microphone permission and return the status.
  static Future<PermissionStatus> requestMicrophonePermission({
    NitroCamera? native,
  }) async {
    final v = await (native ?? NitroCamera.instance)
        .requestMicrophonePermission();
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
    // Without an explicit format/size, target 1080p and let the native
    // resolver negotiate the closest supported size. Falling back to
    // `device.formats.first` here used to inherit the platform's enumeration
    // order — descending on Android (a 4K preview by default) and roughly
    // ascending on iOS (a tiny one). vision-camera #4083 parity: the preview
    // should not bias towards 4K unless the caller asks for it.
    final fmt = format;
    final w = width ?? fmt?.videoWidth ?? 1920;
    final h = height ?? fmt?.videoHeight ?? 1080;
    final targetFps = fps ?? fmt?.maxFps.toInt() ?? 30;

    final tid = await _native.openCamera(
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
    SessionState? st;
    try {
      st = getSessionState();
      if (st.width > 0 && st.height > 0) {
        aw = st.width;
        ah = st.height;
      }
    } catch (_) {}
    _width = aw;
    _height = ah;
    _sensorOrientation = device.sensorOrientation;
    _isActive = true;
    _watchNativeRecordingState();
    _configuration = CameraConfiguration(
      deviceId: device.id,
      format: fmt,
      fps: targetFps,
      enableAudio: audio,
      isActive: true,
    );
    _resolvedConfig = _resolvedFrom(_configuration!, session: st);
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
      if (old != null) await _native.closeCamera(old);
      final w = next.format?.videoWidth ?? _width;
      final h = next.format?.videoHeight ?? _height;
      final tid = await _native.openCamera(
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

    final cam = _native;
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
    _watchNativeRecordingState();
    _configuration = CameraConfiguration(
      deviceId: device.id,
      fps: fps,
      isActive: true,
    );
    _resolvedConfig = _resolvedFrom(_configuration!);
    notifyListeners();
  }

  /// Subscription that keeps Dart-side recording state honest.
  StreamSubscription<CameraEvent>? _recordingWatch;

  /// Mirrors NATIVE recording termination into Dart state.
  ///
  /// A recording can end without Dart asking: `maxDurationMs` / `maxFileSizeBytes`
  /// auto-stops and an encoder failure are all finalised natively, which emits a
  /// `stopped` (or `error`) event and never returns through [stopRecording].
  /// Without this, [isRecording] stays `true` forever and every app built on it
  /// keeps showing a live-recording UI for a recording that already ended —
  /// reproduced on a OnePlus CPH2447 by `combo/record_auto_stop_test.dart`.
  void _watchNativeRecordingState() {
    _recordingWatch?.cancel();
    _recordingWatch = _native.eventStream
        .where((e) => e.textureId == _textureId)
        .where(CameraSessionEvent.isKnownType)
        .listen((e) {
          final type = CameraSessionEvent.fromNative(e).type;
          final ended =
              type == CameraEventType.stopped || type == CameraEventType.error;
          if (!ended || !_isRecording) return;
          _isRecording = false;
          _isRecordingPaused = false;
          notifyListeners();
        });
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
      await _native.closeCamera(tid);
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    unawaited(_recordingWatch?.cancel());
    _recordingWatch = null;
    final tid = _textureId;
    _textureId = null;
    if (tid != null && !_sessionClosed) {
      _sessionClosed = true;
      await _native.closeCamera(tid);
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
    _native.setZoom(_textureId!, clamped);
    _zoom = clamped;
    _patchConfig((c) => c.copyWith(zoom: clamped));
    notifyListeners();
  }

  /// Focus at the normalised coordinates ([x], [y]) in range 0.0–1.0.
  /// Mirrors `camera.focus(point)` in vision_camera.
  void focus(double x, double y) {
    _requireInitialized();
    _native.setFocusPoint(_textureId!, x, y);
  }

  /// Sets the auto-focus mode.
  void setAutoFocus(AutoFocusMode mode) {
    _requireInitialized();
    _native.setAutoFocus(_textureId!, mode.nativeValue);
    _patchConfig((c) => c.copyWith(autoFocus: mode));
  }

  /// Manually fixes the focus distance: [distance] 0.0 (far / infinity) to
  /// 1.0 (nearest). Pass a negative value to restore continuous auto-focus.
  /// Fixed-focus lenses (and iOS devices without custom-lens-position support)
  /// ignore it. See [CameraDeviceInfo.minFocusDistanceCm] for the near limit.
  void setFocusDistance(double distance) {
    _requireInitialized();
    _native.setFocusDistance(_textureId!, distance);
  }

  /// Manual exposure: fixes ISO ([iso], e.g. 100-3200) and shutter time
  /// ([exposureDuration]). Both are clamped to the device's range. Pass a
  /// non-positive [iso] to restore automatic exposure.
  void setManualExposure({required double iso, required Duration exposureDuration}) {
    _requireInitialized();
    _native.setManualExposure(
        _textureId!, iso, exposureDuration.inMicroseconds * 1000.0);
  }

  /// Restores automatic exposure after [setManualExposure].
  void setAutoExposure() {
    _requireInitialized();
    _native.setManualExposure(_textureId!, -1, -1);
  }

  /// Exposure bias in the range [device.minExposure] .. [device.maxExposure].
  void setExposure(double value) {
    _requireInitialized();
    _native.setExposure(_textureId!, value);
    _exposure = value;
    _patchConfig((c) => c.copyWith(exposure: value));
    notifyListeners();
  }

  /// Flash mode for photo capture.
  void setFlash(FlashMode mode) {
    _requireInitialized();
    _native.setFlash(_textureId!, mode.nativeValue);
    _flash = mode;
    _patchConfig((c) => c.copyWith(flash: mode));
    notifyListeners();
  }

  /// Continuous torch (flashlight) on/off.
  void setTorch({required bool enabled}) {
    _requireInitialized();
    _native.setTorch(_textureId!, enabled ? 1 : 0);
    _torch = enabled;
    _patchConfig((c) => c.copyWith(torch: enabled));
    notifyListeners();
  }

  /// White balance colour temperature in Kelvin. Pass 0 to restore auto.
  void setWhiteBalance(int kelvin) {
    _requireInitialized();
    _native.setWhiteBalance(_textureId!, kelvin);
    _patchConfig((c) => c.copyWith(whiteBalanceKelvin: kelvin));
  }

  /// Enables or disables HDR mode.
  void setHdr({required bool enabled}) {
    _requireInitialized();
    _native.setHdr(_textureId!, enabled ? 1 : 0);
    _patchConfig((c) => c.copyWith(videoHdr: enabled));
  }

  /// Frame-stream pixel format.
  void setPixelFormat(PixelFormat format) {
    _requireInitialized();
    _native.setFrameFormat(_textureId!, format.nativeValue);
    _patchConfig((c) => c.copyWith(pixelFormat: format));
  }

  /// Reads the live native session state (running / resolution / fps / pixel
  /// format) as a typed [SessionState].
  SessionState getSessionState() {
    _requireInitialized();
    return SessionState.fromJson(
      _native.getSessionStateJson(_textureId!),
    );
  }

  /// Deliver every Nth frame to [frameStream] (1 = every frame).
  void setSamplingRate(int rate) {
    _requireInitialized();
    _native.setSamplingRate(_textureId!, rate);
    _patchConfig((c) => c.copyWith(samplingRate: rate));
  }

  /// Video stabilization mode.
  void setVideoStabilization(VideoStabilizationMode mode) {
    _requireInitialized();
    _native.setVideoStabilization(_textureId!, mode.nativeValue);
    _patchConfig((c) => c.copyWith(videoStabilization: mode));
  }

  /// Enables or disables low-light boost (night mode).
  void setLowLightBoost({required bool enabled}) {
    _requireInitialized();
    _native.setLowLightBoost(_textureId!, enabled ? 1 : 0);
    _patchConfig((c) => c.copyWith(lowLightBoost: enabled));
  }

  /// Torch brightness in 0.0..1.0 (1.0 = max). Values > 0 imply torch on.
  void setTorchLevel(double level) {
    _requireInitialized();
    _native.setTorchLevel(_textureId!, level.clamp(0.0, 1.0));
    _torch = level > 0;
    _patchConfig((c) => c.copyWith(torch: level > 0));
  }

  /// Locks / unlocks auto-exposure at its current value.
  void lockExposure({required bool locked}) {
    _requireInitialized();
    _native.lockExposure(_textureId!, locked ? 1 : 0);
  }

  /// Locks / unlocks focus at its current position.
  void lockFocus({required bool locked}) {
    _requireInitialized();
    _native.lockFocus(_textureId!, locked ? 1 : 0);
  }

  /// Locks / unlocks white balance at its current gains.
  void lockWhiteBalance({required bool locked}) {
    _requireInitialized();
    _native.lockWhiteBalance(_textureId!, locked ? 1 : 0);
  }

  /// Sets the target output orientation in degrees (0 / 90 / 180 / 270).
  void setTargetOrientation(int degrees) {
    _requireInitialized();
    _native.setTargetOrientation(_textureId!, degrees);
  }

  /// Enables / disables lens distortion correction (default ON where the
  /// device supports it — API 28+). vision-camera's
  /// `enableDistortionCorrection`.
  void setDistortionCorrection({required bool enabled}) {
    _requireInitialized();
    _native.setDistortionCorrection(_textureId!, enabled ? 1 : 0);
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

  /// Runs a NATIVE detector on this session's frames by registered name —
  /// `"barcode"` / `"face"` (built-ins), `""` to stop, or the name of a custom
  /// detector the host app registered via `NitraDetectors.register(...)`
  /// (Kotlin/Swift). Results arrive on [detections] / [nativeDetections].
  ///
  /// For the built-ins prefer [startDetector] / [stopDetector]; use this string
  /// overload to select a custom registered detector.
  void setNativeDetector(String detector) {
    _requireInitialized();
    _native.setNativeDetector(_textureId!, detector);
  }

  /// Decoded native-detector results for THIS session, as parsed JSON maps
  /// (`{detector, width, height, rotation, results: [...]}`).
  ///
  /// Prefer the typed [detections] stream.
  Stream<Map<String, dynamic>> get nativeDetections => _native.eventStream.where((e) => e.type == CameraEventType.detection.index && (e.textureId == _textureId || e.textureId == 0)).map((e) {
    try {
      return jsonDecode(e.message) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{'error': 'bad detection payload'};
    }
  });

  /// Camera-ID combinations that can stream CONCURRENTLY (multi-cam, API 30+).
  /// Each inner list is one combination that [initialize] can open as
  /// simultaneous [CameraController] instances. Empty when unsupported.
  static List<List<String>> getConcurrentCameraIds({
    NitroCamera? native,
  }) {
    final json = (native ?? NitroCamera.instance).getConcurrentCameraIdsJson();
    try {
      final raw = jsonDecode(json);
      return (raw as List).map((combo) => (combo as List).cast<String>()).toList();
    } catch (e) {
      // A malformed payload must not masquerade as "multi-cam unsupported"
      // (the native side reports that as a well-formed empty array).
      throw SessionException.malformedPayload('concurrent-camera-IDs', e);
    }
  }

  /// Turns the raw concurrent-camera ID combinations into typed
  /// [ConcurrentCameraSet]s using the enumerated [devices]. A combo is dropped
  /// if any of its IDs is not present in [devices] (a stale/foreign id). Pure —
  /// no native calls, so it is unit-testable off-device.
  static List<ConcurrentCameraSet> resolveConcurrentSets(
    List<List<String>> idCombos,
    List<CameraDeviceInfo> devices,
  ) {
    final byId = {for (final d in devices) d.id: d};
    final sets = <ConcurrentCameraSet>[];
    for (final combo in idCombos) {
      final resolved = <CameraDeviceInfo>[];
      var complete = true;
      for (final id in combo) {
        final d = byId[id];
        if (d == null) {
          complete = false;
          break;
        }
        resolved.add(d);
      }
      if (complete && resolved.isNotEmpty) {
        sets.add(ConcurrentCameraSet(resolved));
      }
    }
    return sets;
  }

  /// The first [ConcurrentCameraSet] that contains a device facing [a] and
  /// (when given) [b] — e.g. `pickConcurrentSet(sets, a: back, b: front)` for a
  /// main-plus-selfie layout. Returns null when no combination qualifies.
  static ConcurrentCameraSet? pickConcurrentSet(
    List<ConcurrentCameraSet> sets, {
    required CameraPosition a,
    CameraPosition? b,
  }) {
    for (final s in sets) {
      if (s.byPosition(a) == null) continue;
      if (b != null && s.byPosition(b) == null) continue;
      return s;
    }
    return null;
  }

  /// Convenience: the platform's concurrent-camera combinations as typed
  /// [ConcurrentCameraSet]s (combines [getConcurrentCameraIds] with
  /// [getAvailableCameraDevices]). Empty when multi-cam is unsupported.
  static Future<List<ConcurrentCameraSet>> getConcurrentCameraSets({
    NitroCamera? native,
  }) async {
    final n = native ?? NitroCamera.instance;
    final combos = getConcurrentCameraIds(native: n);
    final devices = await getAvailableCameraDevices(native: n);
    return resolveConcurrentSets(combos, devices);
  }

  // ---- Photo capture ----

  /// Captures a photo. Returns the file path and metadata.
  Future<PhotoResult> takePhoto() async {
    _requireInitialized();
    return await _native.takePhoto(_textureId!);
  }

  /// Captures a photo with explicit [options] (flash, quality, shutter sound…).
  Future<PhotoResult> takePhotoWithOptions(PhotoCaptureOptions options) async {
    _requireInitialized();
    return await _native.takePhotoWithOptions(_textureId!, options.toNative());
  }

  /// Captures the current preview frame as a fast JPEG snapshot (no full
  /// still-capture round-trip).
  Future<PhotoResult> takeSnapshot() async {
    _requireInitialized();
    return await _native.takeSnapshot(_textureId!);
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
      await _native.startVideoRecording(
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
    _native.pauseRecording(_textureId!);
    _isRecordingPaused = true;
    notifyListeners();
  }

  /// Resumes a paused recording.
  void resumeRecording() {
    _requireInitialized();
    if (!_isRecording || !_isRecordingPaused) return;
    _native.resumeRecording(_textureId!);
    _isRecordingPaused = false;
    notifyListeners();
  }

  /// Stops and finalises the recording. Returns the file path and metadata.
  ///
  /// Throws a [RecorderException] (`recorder/finalize-failed`) when the native
  /// recorder could not write a playable file — e.g. no frames ever reached
  /// the encoder, so finalising the container failed. The truncated file is
  /// deleted natively; there is no partial output to salvage.
  Future<RecordingResult> stopRecording() async {
    _requireInitialized();
    final RecordingResult result;
    try {
      result = await _native.stopVideoRecording(_textureId!);
    } catch (e) {
      // iOS surfaces a failed finalize as a thrown error; normalise it to the
      // same typed exception Android's `failed` reason maps to below.
      _isRecording = false;
      _isRecordingPaused = false;
      notifyListeners();
      if (e is CameraException) rethrow;
      throw RecorderException('recorder/finalize-failed', 'Failed to finalise recording: $e', cause: e);
    }
    _isRecording = false;
    _isRecordingPaused = false;
    notifyListeners();
    if (result.reason == RecordingFinishedReason.failed) {
      throw const RecorderException(
        'recorder/finalize-failed',
        'Recording could not be finalised — no playable video was written; the truncated file was discarded.',
      );
    }
    return result;
  }

  /// Cancels the recording and deletes the temporary file.
  void cancelRecording() {
    _requireInitialized();
    if (!_isRecording) return;
    _native.cancelRecording(_textureId!);
    _isRecording = false;
    _isRecordingPaused = false;
    notifyListeners();
  }

  // ---- High-speed (slow-motion) recording ----

  /// Starts a slow-motion recording to [outputPath] at [fps] (typically 120 or
  /// 240). Uses a dedicated high-speed capture session; photo capture and frame
  /// processing are unavailable until [stopHighSpeedRecording] is called.
  ///
  /// Returns `true` when the recording started, or `false` when the device
  /// advertises no high-speed configuration reaching [fps] (the normal preview
  /// keeps running unchanged). Throws a [RecorderException] on a hardware or
  /// encoder failure while switching sessions.
  Future<bool> startHighSpeedRecording(String outputPath, {int fps = 240}) async {
    _requireInitialized();
    if (_isRecording) return false;
    final int ok;
    try {
      ok = await _native.startHighSpeedRecording(_textureId!, outputPath, fps);
    } on CameraException {
      rethrow;
    } catch (e) {
      throw RecorderException(
        'recorder/high-speed-start-failed',
        'Failed to start high-speed recording: $e',
        cause: e,
      );
    }
    if (ok == 0) return false;
    _isRecording = true;
    _isRecordingPaused = false;
    notifyListeners();
    return true;
  }

  /// Stops a slow-motion recording started with [startHighSpeedRecording] and
  /// restores the normal preview session. Returns the file path and metadata.
  Future<RecordingResult> stopHighSpeedRecording() async {
    _requireInitialized();
    final RecordingResult result;
    try {
      result = await _native.stopHighSpeedRecording(_textureId!);
    } catch (e) {
      _isRecording = false;
      _isRecordingPaused = false;
      notifyListeners();
      if (e is CameraException) rethrow;
      throw RecorderException(
        'recorder/finalize-failed',
        'Failed to finalise high-speed recording: $e',
        cause: e,
      );
    }
    _isRecording = false;
    _isRecordingPaused = false;
    notifyListeners();
    if (result.reason == RecordingFinishedReason.failed) {
      throw const RecorderException(
        'recorder/finalize-failed',
        'High-speed recording could not be finalised; the truncated file was discarded.',
      );
    }
    return result;
  }

  // ---- Frame processing ----

  /// Enables or disables raw frame delivery via [frameStream].
  void setFrameProcessing({required bool enabled}) {
    _requireInitialized();
    _native.enableFrameProcessing(_textureId!, enabled ? 1 : 0);
    _patchConfig((c) => c.copyWith(enableFrameProcessing: enabled));
  }

  /// Enables raw frame delivery via [frameStream].
  void enableFrameProcessing() => setFrameProcessing(enabled: true);

  /// Disables raw frame delivery.
  void disableFrameProcessing() => setFrameProcessing(enabled: false);

  /// Stream of raw camera frames for **this** session (only active after
  /// [enableFrameProcessing]). Frames from other concurrently-open sessions
  /// (multi-cam, the double-buffered switch window) are filtered out.
  Stream<CameraFrame> get frameStream => _native.frameStream.where((f) => f.textureId == _textureId);

  /// Typed session events (started / stopped / error / interruption) for **this**
  /// session. Mirrors vision-camera's session listeners.
  ///
  /// Events with a type index unknown to this plugin version (native/plugin
  /// version skew) are skipped rather than crashing the stream.
  Stream<CameraSessionEvent> get events => _native.eventStream.where(CameraSessionEvent.isKnownType).map(CameraSessionEvent.fromNative).where((e) => e.textureId == _textureId || e.textureId == 0);

  /// Typed session events from an explicit bridge — the injectable form of
  /// [allEvents], used by [thermalStates] and by tests.
  static Stream<CameraSessionEvent> allEventsOf(NitroCamera native) => native
      .eventStream
      .where(CameraSessionEvent.isKnownType)
      .map(CameraSessionEvent.fromNative);

  /// Typed session events across **all** open sessions.
  static Stream<CameraSessionEvent> get allEvents =>
      allEventsOf(NitroCamera.instance);

  /// Typed frame-drop reasons for **this** session (vision-camera's
  /// `onFrameDropped`) — a sustained stream of these means the frame processor
  /// can't keep up (drop-latest backpressure is discarding frames).
  Stream<FrameDropReason> get frameDropReasons => events.where((e) => e.type == CameraEventType.frameDropped).map((e) => FrameDropReason.fromMessage(e.message));

  /// Device thermal-pressure changes while this session is open. Shed capture
  /// load (fps / resolution / HDR) as this climbs toward
  /// [ThermalState.critical] to avoid a HAL throttle or shutdown. Monitoring
  /// auto-starts with the session (no enable call needed).
  Stream<ThermalState> get thermalStates => allEventsOf(_native)
      .where((e) => e.type == CameraEventType.thermalStateChanged)
      .map((e) => ThermalState.fromLevel(e.rawReason));

  /// Updates the GPU filter shader applied to the preview.
  void setFilterShader(String glslSource) {
    _requireInitialized();
    _native.setFilterShader(_textureId!, glslSource);
    _patchConfig((c) => c.copyWith(filterShader: glslSource));
  }

  // ---- Internal ----

  void _requireInitialized() {
    if (!isInitialized || _isDisposed) {
      throw SessionException.notInitialized();
    }
  }
}
