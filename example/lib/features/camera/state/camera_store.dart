import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

enum CameraStatus { closed, opening, closing, running, error }

/// Central reactive store for the demo, built on `signals`.
///
/// Good-practice notes:
///  * it's an **instance** (exposed as the [cameraStore] singleton), not a bag
///    of statics — easy to reset / re-create in tests;
///  * derived state uses [computed] (`isRunning`, `canCapture`, `currentFormat`);
///  * cross-cutting reactions use [effect] (auto-dismiss errors);
///  * every native capability is reachable through the typed [CameraController]
///    published on session start ([onSessionReady]).
class CameraStore {
  CameraStore() {
    // Auto-dismiss transient errors after a few seconds.
    effect(() {
      final msg = errorMessage.value;
      if (msg != null) {
        Future.delayed(const Duration(seconds: 4), () {
          if (errorMessage.value == msg) errorMessage.value = null;
        });
      }
    });
  }

  // ── Devices & session ──────────────────────────────────────────────────────
  final devices = signal<List<CameraDeviceInfo>>([]);
  final currentDevice = signal<CameraDeviceInfo?>(null);
  final loading = signal(true);
  final errorMessage = signal<String?>(null);
  final status = signal<CameraStatus>(CameraStatus.closed);
  final activeTextureId = signal<int?>(null);
  final cameraPermission = signal(0); // 0 unknown, 1 granted, 2 denied

  /// The vision-camera-style controller for the running session. Every control
  /// + capture op routes through it (published by [onSessionReady]).
  final activeController = signal<CameraController?>(null);

  /// Read-back of what the session actually negotiated (VC onSessionConfigSelected).
  final resolvedConfig = signal<ResolvedCameraConfig?>(null);

  /// Rolling log of native session events (started/stopped/error/interruption).
  final sessionEvents = signal<List<CameraSessionEvent>>([]);
  final lastEvent = signal<CameraSessionEvent?>(null);
  StreamSubscription<CameraSessionEvent>? _eventSub;

  // ── Capture ────────────────────────────────────────────────────────────────
  final isRecording = signal(false);
  final recordingDuration = signal(0);
  final isCapturing = signal(false);
  final lastCapturedPath = signal<String?>(null);
  final isLastCapturedVideo = signal(false);
  final capturedMedia = signal<List<({String path, bool isVideo})>>([]);
  final photoTrigger = signal(0);
  final photoQuality = signal(QualityPrioritization.balanced);
  Timer? _recordingTimer;

  // ── Live settings ──────────────────────────────────────────────────────────
  final flashMode = signal(FlashMode.off);
  final currentZoom = signal(1.0);
  final exposure = signal(0.0);
  final whiteBalanceKelvin = signal(0); // 0 = auto
  final hdrEnabled = signal(false);
  final lowLightBoost = signal(false);
  final torch = signal(false);
  final torchLevel = signal(1.0);
  final autoFocusMode = signal(AutoFocusMode.continuous);
  final exposureLocked = signal(false);
  final focusLocked = signal(false);
  final whiteBalanceLocked = signal(false);
  final videoStabilization = signal(0);

  // ── Format / stream config (drives session reopen) ─────────────────────────
  final width = signal(1920);
  final height = signal(1080);
  final fps = signal(60);
  final pixelFormat = signal(1); // 1 = BGRA
  final samplingRate = signal(1);
  final isProcessingFrames = signal(false);

  // ── UI ─────────────────────────────────────────────────────────────────────
  final mode = signal('PHOTO'); // PHOTO | VIDEO | SCANNER
  final currentFilterName = signal('NORMAL');
  final focusIndicatorTrigger = signal<Offset?>(null);
  final controlMode = signal('FILTERS');
  final selectedAspectRatio = signal<double?>(null);
  final showFilters = signal(false);
  final previewMode = signal<PreviewMode>(PreviewMode.texture);

  static const Map<String, String> filters = {
    'NORMAL': '',
    'INVERT':
        'void main() { vec4 c = inputColor; fragColor = vec4(1.0 - c.rgb, c.a); }',
    'GRAYSCALE':
        'void main() { vec4 c = inputColor; float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114)); fragColor = vec4(vec3(luma), c.a); }',
    'SEPIA':
        'void main() { vec4 c = inputColor; vec3 res = vec3(dot(c.rgb, vec3(0.393, 0.769, 0.189)), dot(c.rgb, vec3(0.349, 0.686, 0.168)), dot(c.rgb, vec3(0.272, 0.534, 0.131))); fragColor = vec4(res, c.a); }',
    'VIGNETTE':
        'void main() { vec4 c = inputColor; float d = distance(uv, vec2(0.5)); float v = smoothstep(0.8, 0.3, d); fragColor = vec4(c.rgb * v, c.a); }',
    'CYBERPUNK':
        'void main() { vec4 c = inputColor; float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114)); vec3 pink = vec3(1.0, 0.0, 1.0); vec3 blue = vec3(0.0, 1.0, 1.0); fragColor = vec4(mix(blue, pink, luma), c.a); }',
  };

  // ── Derived (computed) ──────────────────────────────────────────────────────
  late final isRunning =
      computed(() => status.value == CameraStatus.running);
  late final canCapture =
      computed(() => activeController.value != null && !isCapturing.value);
  late final currentFormat = computed(() {
    final d = currentDevice.value;
    if (d == null) return null;
    // Negotiate the best format for the requested resolution + fps.
    return FormatResolver.resolve(d, [
      ResolutionConstraint(TargetResolution.closestTo(width.value, height.value)),
      FpsConstraint(fps.value.toDouble()),
    ]);
  });

  // ── Session lifecycle ───────────────────────────────────────────────────────

  /// Called by `CameraView.onInitialized` — publishes the controller, subscribes
  /// to its event stream, and re-applies the current UI settings to the fresh
  /// native session.
  void onSessionReady(CameraController controller) {
    activeController.value = controller;
    activeTextureId.value = controller.textureId;
    status.value = CameraStatus.running;
    resolvedConfig.value = controller.resolvedConfig;

    _eventSub?.cancel();
    _eventSub = controller.events.listen((e) {
      lastEvent.value = e;
      final log = [...sessionEvents.value, e];
      sessionEvents.value =
          log.length > 20 ? log.sublist(log.length - 20) : log;
      if (e.isError) errorMessage.value = e.message;
    });

    reapplyCurrentSettings();
  }

  /// Called by `CameraView.onClosing` — drop the (soon-disposed) controller.
  void onSessionClosing() {
    _eventSub?.cancel();
    _eventSub = null;
    activeController.value = null;
  }

  /// Re-applies every live setting to a freshly-opened session (needed after a
  /// device switch, which creates a brand-new native session).
  void reapplyCurrentSettings() {
    final ctrl = activeController.value;
    if (ctrl == null || !ctrl.isInitialized) return;
    // Native setters are already capability-guarded, but wrap defensively so a
    // single unsupported control on an odd device can never abort session start.
    try {
      ctrl
        ..setPixelFormat(PixelFormat.fromNative(pixelFormat.value))
        ..setSamplingRate(samplingRate.value)
        ..setVideoStabilization(VideoStabilizationMode.values[videoStabilization.value])
        ..setFilterShader(filters[currentFilterName.value] ?? '')
        ..setFlash(flashMode.value)
        ..setZoom(currentZoom.value)
        ..setExposure(exposure.value)
        ..setWhiteBalance(whiteBalanceKelvin.value)
        ..setHdr(enabled: hdrEnabled.value)
        ..setLowLightBoost(enabled: lowLightBoost.value)
        ..setAutoFocus(autoFocusMode.value)
        ..setFrameProcessing(enabled: mode.value == 'SCANNER');
    } catch (e) {
      debugPrint('reapplyCurrentSettings: $e');
    }
    resolvedConfig.value = ctrl.resolvedConfig;
  }

  /// Live native session state (running / resolution / fps / pixelFormat).
  SessionState? sessionState() => activeController.value?.getSessionState();

  // ── Init & permissions ──────────────────────────────────────────────────────

  Future<void> init() async {
    await Future.microtask(() {});
    try {
      if (loading.value && devices.value.isNotEmpty) return;
      loading.value = true;
      final perm = NitroCamera.instance.getCameraPermissionStatus();
      cameraPermission.value = perm;
      if (perm == 1) {
        final loaded = await CameraController.getAvailableCameraDevices();
        devices.value = List.from(loaded);
        final backCam =
            loaded.where((d) => d.position == 1).firstOrNull ?? loaded.firstOrNull;
        if (backCam != null && currentDevice.value == null) {
          await selectDevice(backCam);
        }
      }
      loading.value = false;
    } catch (e) {
      loading.value = false;
      errorMessage.value = e.toString();
    }
  }

  Future<void> grantPermission() async {
    final s = await NitroCamera.instance.requestCameraPermission();
    await NitroCamera.instance.requestMicrophonePermission();
    cameraPermission.value = s;
    if (s == 1) init();
  }

  // ── Devices ──────────────────────────────────────────────────────────────────

  Future<void> selectDevice(CameraDeviceInfo d) async {
    if (currentDevice.value?.id == d.id) return;
    currentDevice.value = d;
    currentZoom.value = d.neutralZoom;
    status.value = CameraStatus.opening;
  }

  void toggleCamera() {
    if (devices.value.length < 2) return;
    final i = devices.value.indexWhere((d) => d.id == currentDevice.value?.id);
    selectDevice(devices.value[(i + 1) % devices.value.length]);
  }

  // ── Mode / stream ─────────────────────────────────────────────────────────────

  Future<void> setMode(String m) async {
    if (mode.value == m) return;
    mode.value = m;
    final scanning = m == 'SCANNER';
    isProcessingFrames.value = scanning;
    // The barcode scanner decodes the luma plane, which only exists in YUV;
    // BGRA bytes decode as noise. Switch pixel format together with the mode.
    setPixelFormat(scanning ? 0 /* YUV */ : 1 /* BGRA */);
    activeController.value?.setFrameProcessing(enabled: scanning);
  }

  void toggleProcessing(bool val) {
    activeController.value?.setFrameProcessing(enabled: val);
    isProcessingFrames.value = val;
  }

  void setResolution(int w, int h) {
    if ((width.value - w).abs() < 10 && (height.value - h).abs() < 10) return;
    width.value = w;
    height.value = h;
  }

  void setFps(int f) => fps.value = f;

  void setPixelFormat(int format) {
    activeController.value?.setPixelFormat(PixelFormat.fromNative(format));
    pixelFormat.value = format;
  }

  void setSamplingRate(int rate) {
    activeController.value?.setSamplingRate(rate);
    samplingRate.value = rate;
  }

  void setVideoStabilization(int m) {
    activeController.value?.setVideoStabilization(VideoStabilizationMode.values[m]);
    videoStabilization.value = m;
  }

  // ── Live controls ─────────────────────────────────────────────────────────────

  void setFlash(FlashMode m) {
    flashMode.value = m;
    activeController.value?.setFlash(m);
  }

  void setZoom(double z) {
    final dev = currentDevice.value;
    if (dev == null) return;
    final clamped = z.clamp(dev.minZoom, dev.maxZoom);
    currentZoom.value = clamped;
    activeController.value?.setZoom(clamped);
  }

  void setExposure(double v) {
    exposure.value = v;
    activeController.value?.setExposure(v);
  }

  void setWhiteBalance(int kelvin) {
    whiteBalanceKelvin.value = kelvin;
    activeController.value?.setWhiteBalance(kelvin);
  }

  void setHdr(bool enabled) {
    hdrEnabled.value = enabled;
    activeController.value?.setHdr(enabled: enabled);
  }

  void setLowLightBoost(bool enabled) {
    lowLightBoost.value = enabled;
    activeController.value?.setLowLightBoost(enabled: enabled);
  }

  void setTorch(bool enabled) {
    torch.value = enabled;
    activeController.value?.setTorch(enabled: enabled);
  }

  void setTorchLevel(double level) {
    torchLevel.value = level;
    torch.value = level > 0;
    activeController.value?.setTorchLevel(level);
  }

  void setAutoFocus(AutoFocusMode m) {
    autoFocusMode.value = m;
    activeController.value?.setAutoFocus(m);
  }

  void lockExposure(bool locked) {
    exposureLocked.value = locked;
    activeController.value?.lockExposure(locked: locked);
  }

  void lockFocus(bool locked) {
    focusLocked.value = locked;
    activeController.value?.lockFocus(locked: locked);
  }

  void lockWhiteBalance(bool locked) {
    whiteBalanceLocked.value = locked;
    activeController.value?.lockWhiteBalance(locked: locked);
  }

  void setTargetOrientation(int degrees) =>
      activeController.value?.setTargetOrientation(degrees);

  void setFocusPoint(double x, double y) => activeController.value?.focus(x, y);

  void setFilter(String name) {
    currentFilterName.value = name;
    activeController.value?.setFilterShader(filters[name] ?? '');
  }

  Future<void> setPreviewMode(PreviewMode m) async {
    previewMode.value = m;
    activeController.value?.setFilterShader(filters[currentFilterName.value] ?? '');
  }

  // ── Capture ────────────────────────────────────────────────────────────────

  Future<void> takePhoto() => _capture(
        () => activeController.value!.takePhotoWithOptions(
          PhotoCaptureOptions(
            flash: flashMode.value,
            quality: photoQuality.value,
          ),
        ),
      );

  /// Fast preview-frame snapshot (no full still-capture round-trip).
  Future<void> takeSnapshot() =>
      _capture(() => activeController.value!.takeSnapshot());

  Future<void> _capture(Future<PhotoResult> Function() run) async {
    if (isCapturing.value || activeController.value == null) return;
    try {
      isCapturing.value = true;
      photoTrigger.value++;
      HapticFeedback.mediumImpact();
      final result = await run();
      batch(() {
        lastCapturedPath.value = result.path;
        isLastCapturedVideo.value = false;
        capturedMedia.value = [
          ...capturedMedia.value,
          (path: result.path, isVideo: false),
        ];
      });
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('Capture failed: $e');
      errorMessage.value = 'Capture failed: $e';
    } finally {
      isCapturing.value = false;
    }
  }

  bool _recordingBusy = false;
  Future<void> toggleRecording() async {
    // Re-entrancy guard: a double-tap while stop() is still awaiting would fire a
    // second stopVideoRecording (isRecording hasn't flipped yet).
    if (_recordingBusy) return;
    _recordingBusy = true;
    try {
      await _toggleRecordingImpl();
    } finally {
      _recordingBusy = false;
    }
  }

  Future<void> _toggleRecordingImpl() async {
    final ctrl = activeController.value;
    if (ctrl == null) return;
    if (isRecording.value) {
      try {
        final result = await ctrl.stopRecording();
        _recordingTimer?.cancel();
        _recordingTimer = null;
        final path = result.path;
        final ok = path.isNotEmpty && File(path).existsSync() && result.fileSize > 0;
        batch(() {
          isRecording.value = false;
          recordingDuration.value = 0;
          if (ok) {
            lastCapturedPath.value = path;
            isLastCapturedVideo.value = true;
            capturedMedia.value = [
              ...capturedMedia.value,
              (path: path, isVideo: true),
            ];
          } else {
            errorMessage.value = 'Recording failed — no video was written.';
          }
        });
      } catch (e) {
        isRecording.value = false;
        _recordingTimer?.cancel();
        _recordingTimer = null;
        errorMessage.value = 'Stop video failed: $e';
      }
    } else {
      try {
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await ctrl.startRecording(path);
        isRecording.value = true;
        recordingDuration.value = 0;
        _recordingTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => recordingDuration.value++,
        );
      } catch (e) {
        errorMessage.value = 'Start video failed: $e';
      }
    }
  }
}

/// App-wide store singleton (idiomatic `signals` global store).
final cameraStore = CameraStore();
