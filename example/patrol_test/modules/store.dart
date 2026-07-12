import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import 'package:nitro_camera_example/features/camera/processors/luminance_processor.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import '../support/frame_stats.dart';
import 'module.dart';

/// Example-app store flows — the Patrol port of the legacy
/// integration_test lifecycle / 4K suites (session-lifecycle discipline:
/// switching storms, processor/scanner handover, resolution reopens).
final class Store extends Module {
  Store(super.$);

  Future<void> _awaitReopen(
    int? beforeTid,
    String reason, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await pumpUntil(
      () =>
          cameraStore.status.value == CameraStatus.running &&
          cameraStore.activeTextureId.value != beforeTid &&
          (cameraStore.activeController.value?.isInitialized ?? false),
      timeout: timeout,
      reason: reason,
    );
  }

  Future<void> _expectFramesFlow({required int after, required String stage}) {
    return pumpUntil(
      () => luminanceProcessor.framesProcessed.value > after,
      reason: 'frames flowing through the processor $stage',
    );
  }

  /// Rapid device switching (default 6 toggles, 1 s gaps) must never surface
  /// an error or wedge the HAL (the OnePlus "unknown device" storm class).
  /// Returns false when the device exposes fewer than 2 cameras.
  Future<bool> rapidSwitchSurvives({int toggles = 6}) async {
    if (cameraStore.devices.value.length < 2) return false;

    for (var i = 1; i <= toggles; i++) {
      final beforeTid = cameraStore.activeTextureId.value;
      cameraStore.toggleCamera();
      await _awaitReopen(
        beforeTid,
        'preview running after toggle $i',
        timeout: const Duration(seconds: 15),
      );
      expect(
        cameraStore.errorMessage.value,
        isNull,
        reason: 'toggle $i must not surface an error',
      );
      await pumpFor(const Duration(seconds: 1));
    }
    expect(cameraStore.status.value, CameraStatus.running);
    return true;
  }

  /// Custom frame processor receives frames, coexists with SCANNER mode, and
  /// survives a lens change (the "changing lens with luminance on stuck the
  /// app" regression).
  Future<void> processorScannerRoundTrip() async {
    cameraStore.setFrameProcessor(luminanceProcessor);
    await _expectFramesFlow(after: 0, stage: 'after install');
    expect(luminanceProcessor.attached.value, isTrue);
    expect(cameraStore.errorMessage.value, isNull);

    await cameraStore.setMode('SCANNER');
    await pumpFor(const Duration(seconds: 2));
    expect(cameraStore.mode.value, 'SCANNER');
    expect(
      cameraStore.frameProcessor.value,
      isNotNull,
      reason: 'custom processor stays installed during SCANNER',
    );
    expect(cameraStore.status.value, CameraStatus.running);

    await cameraStore.setMode('PHOTO');
    await pumpFor(const Duration(seconds: 2));
    expect(cameraStore.frameProcessor.value, isNotNull);
    expect(cameraStore.errorMessage.value, isNull);

    if (cameraStore.devices.value.length > 1) {
      final beforeTid = cameraStore.activeTextureId.value;
      final beforeFrames = luminanceProcessor.framesProcessed.value;
      cameraStore.toggleCamera();
      await _awaitReopen(
        beforeTid,
        'preview running on the new device with processor',
      );
      await _expectFramesFlow(after: beforeFrames, stage: 'after lens change');
      expect(
        luminanceProcessor.attached.value,
        isTrue,
        reason: 'processor re-adopted by the new session',
      );
      expect(cameraStore.errorMessage.value, isNull);
    }

    cameraStore.clearFrameProcessor();
    expect(luminanceProcessor.attached.value, isFalse);
    await pumpFor(const Duration(milliseconds: 500));
  }

  /// Resolution reopen round-trip: 1080p → 720p → 1080p.
  Future<void> resolutionRoundTrip() async {
    Future<void> changeRes(int w, int h) async {
      final beforeTid = cameraStore.activeTextureId.value;
      cameraStore.setResolution(w, h);
      await _awaitReopen(
        beforeTid,
        'session reopened at ${w}x$h',
        timeout: const Duration(seconds: 15),
      );
      expect(cameraStore.errorMessage.value, isNull);
      await pumpFor(const Duration(seconds: 1));
    }

    await changeRes(1280, 720);
    await changeRes(1920, 1080);
    expect(cameraStore.status.value, CameraStatus.running);
  }

  /// 4K reopen: frames must actually FLOW at 4K, the resolved stream must
  /// really be ≥3840 on the long edge, and the round-trip back to 1080p must
  /// survive. Returns false when the sensor advertises no 4K format.
  Future<bool> fourKRoundTrip() async {
    if (!cameraStore.supports4K.value) return false;

    cameraStore.setFrameProcessor(luminanceProcessor);
    await _expectFramesFlow(after: 0, stage: 'at boot resolution');

    final beforeTid = cameraStore.activeTextureId.value;
    cameraStore.setResolution(3840, 2160);
    await _awaitReopen(beforeTid, 'session reopened at 4K');
    expect(cameraStore.errorMessage.value, isNull);

    final at4kStart = luminanceProcessor.framesProcessed.value;
    await _expectFramesFlow(after: at4kStart, stage: 'after 4K switch');

    final state = cameraStore.sessionState();
    expect(state, isNotNull);
    final longEdge = state!.width > state.height ? state.width : state.height;
    expect(state.running, isTrue);
    expect(
      longEdge,
      greaterThanOrEqualTo(3840),
      reason:
          'requested 4K but the resolved stream is '
          '${state.width}x${state.height}',
    );
    expect(cameraStore.resolutionLabel.value, '4K');

    final sustainStart = luminanceProcessor.framesProcessed.value;
    await pumpFor(const Duration(seconds: 2));
    expect(
      luminanceProcessor.framesProcessed.value,
      greaterThan(sustainStart),
      reason: '4K stream died after the first frames',
    );

    final tid4k = cameraStore.activeTextureId.value;
    cameraStore.setResolution(1920, 1080);
    await _awaitReopen(tid4k, 'session reopened back at 1080p');
    final at1080 = luminanceProcessor.framesProcessed.value;
    await _expectFramesFlow(after: at1080, stage: 'back at 1080p');
    expect(cameraStore.errorMessage.value, isNull);

    cameraStore.clearFrameProcessor();
    return true;
  }

  Future<int> _streamFrameCount({
    Duration duration = const Duration(seconds: 2),
  }) async {
    final c = cameraStore.activeController.value!;
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 500));
    final col = FrameStatsCollector()..attach(c.frameStream);
    await pumpFor(duration);
    final r = await col.stop();
    c.setFrameProcessing(enabled: false);
    return r.frameCount;
  }

  /// Device thermal monitoring: a thermal state must be published on (re)open
  /// (auto-started, device-wide). Forces a reopen and asserts a typed
  /// [ThermalState] arrives.
  Future<void> thermalStatePublished() async {
    final states = <ThermalState>[];
    final sub = CameraController.allEvents
        .where((e) => e.type == CameraEventType.thermalStateChanged)
        .map((e) => ThermalState.fromLevel(e.rawReason))
        .listen(states.add);

    final beforeTid = cameraStore.activeTextureId.value;
    cameraStore.setResolution(1280, 720); // force a reopen → re-publish thermal
    await pumpUntil(
      () => cameraStore.activeTextureId.value != beforeTid && states.isNotEmpty,
      timeout: const Duration(seconds: 15),
      reason: 'a thermal state was published on (re)open',
    );
    await sub.cancel();
    expect(ThermalState.values, contains(states.first));
    expect(cameraStore.errorMessage.value, isNull);
    cameraStore.setResolution(1920, 1080); // restore
    await pumpFor(const Duration(seconds: 1));
  }

  /// The typed event `map()` helper routes REAL on-device events (a reopen
  /// emits stopped + started) to their typed branches without throwing.
  Future<void> eventMapRoutesRealEvents() async {
    final labels = <String>[];
    final sub = CameraController.allEvents.listen((e) {
      labels.add(
        e.map(
          started: () => 'started',
          stopped: () => 'stopped',
          error: (m) => 'error:$m',
          orientationChanged: (d) => 'orient:$d',
          thermalChanged: (s) => 'thermal:${s.name}',
          frameDropped: (r) => 'drop:${r.name}',
          deviceHotplug: (id, on) => 'hotplug:$id:$on',
          interruption: (_, ended) => 'interruption:$ended',
          detection: (_) => 'detection',
          orElse: () => 'other:${e.type.name}',
        ),
      );
    });

    final beforeTid = cameraStore.activeTextureId.value;
    cameraStore.setResolution(1280, 720); // reopen → stopped + started
    await pumpUntil(
      () => cameraStore.activeTextureId.value != beforeTid && labels.isNotEmpty,
      timeout: const Duration(seconds: 15),
      reason: 'events routed through map() on reopen',
    );
    await sub.cancel();

    // Every event produced a label (map never threw / left a gap), and the
    // reopen surfaced at least a started event.
    expect(labels, isNotEmpty);
    expect(labels.every((l) => l.isNotEmpty), isTrue);
    expect(
      labels.any((l) => l == 'started' || l == 'thermal:nominal'),
      isTrue,
      reason: 'reopen should surface a started/thermal event ($labels)',
    );
    cameraStore.setResolution(1920, 1080); // restore
    await pumpFor(const Duration(seconds: 1));
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// App background → foreground: the preview must come back (production
  /// interruption handling). If frames don't resume, the session was left
  /// dead on background — a real bug (vision-camera gates an `isActive` flag).
  Future<void> backgroundResumeSurvives() async {
    expect(cameraStore.status.value, CameraStatus.running);
    await $.platform.mobile.pressHome();
    // RAW delay while backgrounded — do NOT pump(): the Flutter engine is
    // paused, so tester.pump() blocks until the app foregrounds again, which
    // would deadlock before openApp() ever runs.
    await Future<void>.delayed(const Duration(seconds: 2));
    await $.platform.mobile.openApp();
    // Let the engine resume before pumping.
    await Future<void>.delayed(const Duration(seconds: 1));

    await pumpUntil(
      () =>
          cameraStore.status.value == CameraStatus.running &&
          (cameraStore.activeController.value?.isInitialized ?? false),
      timeout: const Duration(seconds: 25),
      reason: 'preview running again after background then foreground',
    );
    expect(cameraStore.errorMessage.value, isNull);
    final frames = await _streamFrameCount();
    expect(
      frames,
      greaterThan(5),
      reason: 'no frames after resume — preview stuck after backgrounding',
    );
  }

  /// Rapid PHOTO/VIDEO/SCANNER churn (each flips pixel format → a session
  /// reconfigure). The session must stay healthy and streaming after the
  /// churn, with no error.
  Future<void> rapidModeChurnSurvives() async {
    const seq = [
      'PHOTO',
      'VIDEO',
      'SCANNER',
      'VIDEO',
      'PHOTO',
      'SCANNER',
      'PHOTO',
    ];
    for (final m in seq) {
      await cameraStore.setMode(m);
      await pumpFor(const Duration(milliseconds: 500));
      expect(
        cameraStore.errorMessage.value,
        isNull,
        reason: 'mode $m surfaced an error during churn',
      );
    }
    await pumpUntil(
      () => cameraStore.status.value == CameraStatus.running,
      reason: 'session running after rapid mode churn',
    );
    final frames = await _streamFrameCount();
    expect(
      frames,
      greaterThan(5),
      reason: 'preview stalled after rapid mode churn',
    );
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// STORE-level capture persists to the in-app library and the app survives
  /// the fire-and-forget system-gallery mirror (the missing
  /// NSPhotoLibraryAddUsageDescription TCC-kill regression).
  Future<void> captureAndPersist() async {
    final photosBefore = cameraStore.capturedMedia.value.length;
    await cameraStore.takePhoto();
    await pumpUntil(
      () => cameraStore.capturedMedia.value.length > photosBefore,
      reason: 'store photo captured and persisted',
    );
    expect(cameraStore.errorMessage.value, isNull);

    final mediaBefore = cameraStore.capturedMedia.value.length;
    await cameraStore.toggleRecording();
    expect(
      cameraStore.isRecording.value,
      isTrue,
      reason: 'recording started (error=${cameraStore.errorMessage.value})',
    );
    await pumpFor(const Duration(seconds: 2));
    await cameraStore.toggleRecording();
    await pumpUntil(
      () =>
          !cameraStore.isRecording.value &&
          cameraStore.capturedMedia.value.length > mediaBefore,
      reason: 'recording stopped and persisted to the in-app library',
    );
    expect(cameraStore.errorMessage.value, isNull);

    // "No crash for 5s" IS the assertion for the gallery mirror.
    await pumpFor(const Duration(seconds: 5));
    expect(
      cameraStore.status.value,
      CameraStatus.running,
      reason: 'app survived the system-gallery mirror',
    );
  }
}
