import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../gallery/services/media_services.dart';
import '../processors/frame_processor.dart';

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

  // ── Quick-wins (vision-camera parity) ───────────────────────────────────────
  final videoCodec = signal(VideoCodec.h264);
  final geotagEnabled = signal(false);
  // RAW (DNG) photo capture — only offered when the device supports it.
  final rawPhoto = signal(false);
  // ── User-pluggable frame processor ──────────────────────────────────────────
  // No native ML Kit here: detection/analysis is a Dart-side concern. Apps
  // implement [FrameProcessor] with their own pipeline and plug it in below;
  // the store owns the session plumbing (frame delivery, reattach on reopen).

  /// The active user-supplied frame processor (null = none).
  final frameProcessor = signal<FrameProcessor?>(null);
  StreamSubscription<CameraFrame>? _processorSub;

  /// Live profiling of the active processor (vision-camera's "profile your
  /// frame processor" guidance): processed frames per second and mean
  /// [FrameProcessor.processFrame] cost, refreshed once per second.
  final processorFps = signal(0.0);
  final processorAvgMs = signal(0.0);
  int _statFrames = 0;
  double _statMs = 0;
  int _statWindowStartTs = 0;

  void _resetProcessorStats() {
    _statFrames = 0;
    _statMs = 0;
    _statWindowStartTs = 0;
    processorFps.value = 0.0;
    processorAvgMs.value = 0.0;
  }

  /// Installs (or, with `null`, clears) a custom [FrameProcessor]. The
  /// previous processor gets [FrameProcessor.onDetach]; the new one is
  /// attached to the running session immediately and re-attached automatically
  /// after every camera/format switch. Coexists with SCANNER mode — both are
  /// plain listeners on the same broadcast frame stream.
  void setFrameProcessor(FrameProcessor? processor) {
    final old = frameProcessor.value;
    if (identical(old, processor)) return;
    _processorSub?.cancel();
    _processorSub = null;
    old?.onDetach();
    _resetProcessorStats();
    frameProcessor.value = processor;
    final ctrl = activeController.value;
    if (processor != null && ctrl != null && ctrl.isInitialized) {
      _attachProcessor(processor, ctrl);
    }
    _syncFrameDelivery();
  }

  /// Convenience for `setFrameProcessor(null)`.
  void clearFrameProcessor() => setFrameProcessor(null);

  void _attachProcessor(FrameProcessor processor, CameraController ctrl) {
    processor.onAttach(ctrl);
    _processorSub = ctrl.frameStream.listen(handleFrame);
  }

  /// Routes one delivered frame to the active processor. A throwing processor
  /// must never take down the frame listener (frames keep flowing to the
  /// scanner and future frames to the processor itself).
  @visibleForTesting
  void handleFrame(CameraFrame frame) {
    final p = frameProcessor.value;
    if (p == null) return;
    final sw = Stopwatch()..start();
    try {
      p.processFrame(frame);
    } catch (e) {
      debugPrint('FrameProcessor "${p.name}" failed: $e');
    }
    sw.stop();

    // Profiling window keyed on the frame's own capture timestamp (ms) so
    // the numbers describe the stream, not the wall clock.
    _statFrames++;
    _statMs += sw.elapsedMicroseconds / 1000.0;
    _statWindowStartTs =
        _statWindowStartTs == 0 ? frame.timestamp : _statWindowStartTs;
    final span = frame.timestamp - _statWindowStartTs;
    if (span >= 1000) {
      processorFps.value = _statFrames * 1000 / span;
      processorAvgMs.value = _statMs / _statFrames;
      _statFrames = 0;
      _statMs = 0;
      _statWindowStartTs = frame.timestamp;
    }
  }

  /// Native frame delivery is on when anyone consumes frames: the SCANNER
  /// pipeline and/or a custom [frameProcessor].
  bool get _frameDeliveryNeeded =>
      isProcessingFrames.value || frameProcessor.value != null;

  void _syncFrameDelivery() =>
      activeController.value?.setFrameProcessing(enabled: _frameDeliveryNeeded);
  final showFpsGraph = signal(false);
  final resizeCover = signal(true); // cover vs contain
  final shutterFlash = signal(0); // bump to trigger a shutter flash animation
  final lastThumbnailPath = signal<String?>(null);

  /// Demo geotag (San Francisco). A real app would read GPS via e.g. geolocator.
  static const _demoLocation =
      (latitude: 37.7749, longitude: -122.4194, altitude: 12.0);

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
  // Quick-settings dropdown (resolution / fps / aspect / settings entry)
  // anchored under the top icon strip.
  final quickSettingsOpen = signal(false);
  // Texture by default: renders through Flutter's compositor, so it composes
  // cleanly with overlays/filters on every device; the platform-view path
  // stays opt-in via the top-bar toggle.
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

  /// True while the session is being torn down / reopened (device, resolution
  /// or fps switch) — drives the freeze-dim overlay + flip-button animation.
  late final isSwitching = computed(() =>
      status.value == CameraStatus.opening ||
      status.value == CameraStatus.closing);

  /// Whether the active sensor advertises a 4K (UHD) video format.
  late final supports4K = computed(() =>
      currentDevice.value?.formats.any((f) => f.videoWidth >= 3840) ?? false);

  /// Compact label for the active stream config (e.g. "1080P").
  ///
  /// Prefers the RESOLVED session dimensions over the requested ones so the
  /// badge reflects what the camera actually negotiated (long edge — the
  /// stream is portrait-swapped on iOS). Falls back to the request while a
  /// session is still opening.
  late final resolutionLabel = computed(() {
    final rc = resolvedConfig.value;
    final w = rc != null
        ? (rc.videoWidth > rc.videoHeight ? rc.videoWidth : rc.videoHeight)
        : width.value;
    if (w >= 3840) return '4K';
    if (w >= 1920) return '1080P';
    return '720P';
  });
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
      switch (e.type) {
        case CameraEventType.photoCaptureShutter:
          shutterFlash.value++; // drive a white shutter-flash animation
          break;
        case CameraEventType.photoThumbnail:
          if (e.message.isNotEmpty) lastThumbnailPath.value = e.message;
          break;
        case CameraEventType.stopped:
          // Auto-stop (maxDuration/maxFileSize) delivers the finished path here.
          final p = e.message;
          if (isRecording.value && p.isNotEmpty && File(p).existsSync()) {
            _onRecordingFinished(p);
          }
          break;
        default:
          break;
      }
    });

    unawaited(reapplyCurrentSettings());
  }

  /// Called by `CameraView.onClosing` — drop the (soon-disposed) controller.
  void onSessionClosing() {
    _eventSub?.cancel();
    _eventSub = null;
    // Pause processor frame routing; it re-attaches on the next session
    // (reapplyCurrentSettings). The processor itself stays installed.
    _processorSub?.cancel();
    _processorSub = null;
    activeController.value = null;
    // A resolution/fps change reopens the session without going through
    // [selectDevice]; reflect the teardown in [status] so the switch overlay
    // covers every reopen, not just device switches.
    if (status.value == CameraStatus.running) {
      status.value = CameraStatus.closing;
    }
  }

  /// Re-applies every live setting to a freshly-opened session (needed after a
  /// device switch, which creates a brand-new native session).
  ///
  /// ONE atomic native `configure()` instead of ~13 serialized FFI setters —
  /// each setter is its own boundary crossing and native dispatch, and the
  /// whole storm ran on every session-ready. The controller's declarative
  /// diff path applies only what changed (and never reopens: only live fields
  /// differ from the freshly-seeded configuration).
  Future<void> reapplyCurrentSettings() async {
    final ctrl = activeController.value;
    if (ctrl == null || !ctrl.isInitialized) return;
    // Native config is capability-guarded, but wrap defensively so a single
    // unsupported control on an odd device can never abort session start.
    try {
      final base = ctrl.configuration ?? const CameraConfiguration();
      await ctrl.configure(base.copyWith(
        zoom: currentZoom.value,
        exposure: exposure.value,
        flash: flashMode.value,
        whiteBalanceKelvin: whiteBalanceKelvin.value,
        videoHdr: hdrEnabled.value,
        lowLightBoost: lowLightBoost.value,
        videoStabilization:
            VideoStabilizationMode.values[videoStabilization.value],
        autoFocus: autoFocusMode.value,
        enableFrameProcessing: _frameDeliveryNeeded,
        pixelFormat: PixelFormat.fromNative(pixelFormat.value),
        samplingRate: samplingRate.value,
        filterShader: filters[currentFilterName.value] ?? '',
      ));
      // Not part of the declarative config struct (yet) — keep imperative.
      ctrl.setTargetOrientation(targetOrientation.value);
      // Fresh native session — re-adopt the custom processor (new controller,
      // new frame subscription).
      final p = frameProcessor.value;
      if (p != null) {
        _processorSub?.cancel();
        _attachProcessor(p, ctrl);
      }
    } catch (e) {
      debugPrint('reapplyCurrentSettings: $e');
    }
    resolvedConfig.value = ctrl.resolvedConfig;
  }

  /// Live native session state (running / resolution / fps / pixelFormat).
  SessionState? sessionState() => activeController.value?.getSessionState();

  // ── Init & permissions ──────────────────────────────────────────────────────

  /// In-flight init coalescing: `main()`, `CameraScreen.initState` and the
  /// app-resume lifecycle hook all call [init] around launch — without this
  /// the (slow, native) device enumeration ran twice on every cold boot.
  Future<void>? _initInFlight;

  Future<void> init() {
    final pending = _initInFlight;
    if (pending != null) return pending;
    if (devices.value.isNotEmpty) return Future.value();
    final run = _initImpl();
    _initInFlight = run.whenComplete(() {
      // Allow a re-run when this pass produced no devices (e.g. camera
      // permission still missing) — grantPermission() calls init() again.
      if (devices.value.isEmpty) _initInFlight = null;
    });
    return _initInFlight!;
  }

  Future<void> _initImpl() async {
    await Future.microtask(() {});
    unawaited(hydrateGallery());
    try {
      loading.value = true;
      final perm = NitroCamera.instance.getCameraPermissionStatus();
      cameraPermission.value = perm;
      if (perm == 1) {
        final loaded = await CameraController.getAvailableCameraDevices();
        devices.value = List.from(loaded);
        final backCam =
            loaded.where((d) => d.isBackCamera).firstOrNull ?? loaded.firstOrNull;
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
    // Video-only effects must not bleed into PHOTO/SCANNER: reset video
    // stabilization when leaving VIDEO (leaving it on also costs a preview
    // hitch each reconfigure). Format-time settings (codec) apply at record.
    if (m != 'VIDEO' && videoStabilization.value != 0) {
      setVideoStabilization(0);
    }
    mode.value = m;
    final scanning = m == 'SCANNER';
    isProcessingFrames.value = scanning;
    // The barcode scanner decodes the luma plane, which only exists in YUV;
    // BGRA bytes decode as noise. Switch pixel format together with the mode.
    // (A custom [frameProcessor] must handle both — see FrameProcessor docs.)
    setPixelFormat(scanning ? 0 /* YUV */ : 1 /* BGRA */);
    // Frame delivery stays on if a custom processor is installed, even
    // outside SCANNER — both are plain listeners on the broadcast stream.
    _syncFrameDelivery();
  }

  void toggleProcessing(bool val) {
    isProcessingFrames.value = val;
    _syncFrameDelivery();
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

  /// -1 = AUTO (follow device rotation); 0/90/180/270 = locked.
  final targetOrientation = signal(-1);

  /// Which code family the scanner looks for (QR / 1D / 2D / ALL).
  final scanKind = signal<CodeScanKind>(CodeScanKind.all);

  /// One-shot (stop after first confirmed code) vs continuous scanning.
  final scanOneShot = signal(false);

  void setTargetOrientation(int degrees) {
    targetOrientation.value = degrees;
    activeController.value?.setTargetOrientation(degrees);
  }

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
            location: geotagEnabled.value ? _demoLocation : null,
            outputFormat:
                rawPhoto.value ? PhotoOutputFormat.dng : PhotoOutputFormat.jpeg,
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
      // Move the JPEG/DNG out of the cache dir into the permanent library
      // (byte-preserving, EXIF/GPS intact) before publishing the path.
      final storedPath = await _persistCapture(result.path, isVideo: false);
      batch(() {
        lastCapturedPath.value = storedPath;
        isLastCapturedVideo.value = false;
        capturedMedia.value = [
          ...capturedMedia.value,
          (path: storedPath, isVideo: false),
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
        final path = result.path;
        final ok = path.isNotEmpty && File(path).existsSync() && result.fileSize > 0;
        if (ok) {
          _onRecordingFinished(path,
              duration: Duration(milliseconds: result.durationMs));
        } else {
          _recordingTimer?.cancel();
          _recordingTimer = null;
          batch(() {
            isRecording.value = false;
            recordingDuration.value = 0;
            errorMessage.value = 'Recording failed — no video was written.';
          });
        }
      } catch (e) {
        isRecording.value = false;
        _recordingTimer?.cancel();
        _recordingTimer = null;
        errorMessage.value = 'Stop video failed: $e';
      }
    } else {
      try {
        final dir = await getTemporaryDirectory();
        final ext = videoCodec.value == VideoCodec.hevc ? 'mov' : 'mp4';
        final path =
            '${dir.path}/video_${DateTime.now().millisecondsSinceEpoch}.$ext';
        await ctrl.startRecording(
          path,
          options: RecordingOptions(
            codec: videoCodec.value.nativeValue,
            fileType: videoCodec.value == VideoCodec.hevc
                ? VideoFileType.mov.nativeValue
                : VideoFileType.mp4.nativeValue,
            latitude: geotagEnabled.value ? _demoLocation.latitude : 0,
            longitude: geotagEnabled.value ? _demoLocation.longitude : 0,
            altitude: geotagEnabled.value ? _demoLocation.altitude : 0,
            hasLocation: geotagEnabled.value ? 1 : 0,
          ),
        );
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

  /// Shared finalisation for a completed recording (manual stop or native
  /// maxDuration/maxFileSize auto-stop).
  void _onRecordingFinished(String path, {Duration? duration}) {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    batch(() {
      isRecording.value = false;
      recordingDuration.value = 0;
    });
    unawaited(_finishVideo(path, duration: duration));
  }

  Future<void> _finishVideo(String path, {Duration? duration}) async {
    final storedPath = await _persistCapture(path, isVideo: true);
    // Seed the gallery's duration cache from the recorder result so the tile
    // never has to probe the file (the probe was the iOS 26 crash path).
    if (duration != null && duration > Duration.zero) {
      unawaited(MediaServices.thumbnails.primeDuration(storedPath, duration));
    }
    batch(() {
      lastCapturedPath.value = storedPath;
      isLastCapturedVideo.value = true;
      capturedMedia.value = [
        ...capturedMedia.value,
        (path: storedPath, isVideo: true),
      ];
    });
  }

  // ── Media library ──────────────────────────────────────────────────────────

  bool _galleryHydrated = false;

  /// Rebuilds [capturedMedia] from the on-disk captures library so the gallery
  /// persists across app launches. Runs once per process.
  Future<void> hydrateGallery() async {
    if (_galleryHydrated) return;
    _galleryHydrated = true;
    try {
      final items = await MediaServices.storage.loadAll(); // newest first
      if (items.isEmpty) return;
      batch(() {
        // The store keeps capture order (oldest → newest); UIs reverse it.
        capturedMedia.value = [...items.reversed];
        lastCapturedPath.value = items.first.path;
        isLastCapturedVideo.value = items.first.isVideo;
      });
    } catch (e) {
      debugPrint('Gallery hydration failed: $e');
    }
  }

  /// Moves a finished capture into the permanent library (rename/copy — bytes
  /// and EXIF untouched) and mirrors it to the system gallery, best-effort.
  Future<String> _persistCapture(String rawPath, {required bool isVideo}) async {
    var path = rawPath;
    try {
      path = await MediaServices.storage
          .persist(rawPath, capturedAt: DateTime.now());
    } catch (e) {
      debugPrint('Capture persist failed (keeping cache path): $e');
    }
    unawaited(MediaServices.systemGallery.trySave(path, isVideo: isVideo));
    return path;
  }

  /// Deletes a gallery item: store entry, file, and cached video artifacts.
  Future<void> removeMedia(String path) async {
    final wasVideo =
        capturedMedia.value.any((m) => m.path == path && m.isVideo);
    batch(() {
      capturedMedia.value = [
        for (final m in capturedMedia.value)
          if (m.path != path) m,
      ];
      if (lastCapturedPath.value == path) {
        final last = capturedMedia.value.lastOrNull;
        lastCapturedPath.value = last?.path;
        isLastCapturedVideo.value = last?.isVideo ?? false;
      }
    });
    await MediaServices.storage.delete(path);
    if (wasVideo) await MediaServices.thumbnails.evict(path);
  }
}

/// App-wide store singleton (idiomatic `signals` global store).
final cameraStore = CameraStore();
