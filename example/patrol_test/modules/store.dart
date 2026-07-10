import 'package:flutter_test/flutter_test.dart';

import 'package:nitro_camera_example/features/camera/processors/luminance_processor.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import 'module.dart';

/// Example-app store flows — the Patrol port of the legacy
/// integration_test lifecycle / 4K suites (session-lifecycle discipline:
/// switching storms, processor/scanner handover, resolution reopens).
final class Store extends Module {
  Store(super.$);

  Future<void> _awaitReopen(int? beforeTid, String reason,
      {Duration timeout = const Duration(seconds: 20)}) async {
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
      await _awaitReopen(beforeTid, 'preview running after toggle $i',
          timeout: const Duration(seconds: 15));
      expect(cameraStore.errorMessage.value, isNull,
          reason: 'toggle $i must not surface an error');
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
    expect(cameraStore.frameProcessor.value, isNotNull,
        reason: 'custom processor stays installed during SCANNER');
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
          beforeTid, 'preview running on the new device with processor');
      await _expectFramesFlow(after: beforeFrames, stage: 'after lens change');
      expect(luminanceProcessor.attached.value, isTrue,
          reason: 'processor re-adopted by the new session');
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
      await _awaitReopen(beforeTid, 'session reopened at ${w}x$h',
          timeout: const Duration(seconds: 15));
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
    expect(longEdge, greaterThanOrEqualTo(3840),
        reason: 'requested 4K but the resolved stream is '
            '${state.width}x${state.height}');
    expect(cameraStore.resolutionLabel.value, '4K');

    final sustainStart = luminanceProcessor.framesProcessed.value;
    await pumpFor(const Duration(seconds: 2));
    expect(luminanceProcessor.framesProcessed.value, greaterThan(sustainStart),
        reason: '4K stream died after the first frames');

    final tid4k = cameraStore.activeTextureId.value;
    cameraStore.setResolution(1920, 1080);
    await _awaitReopen(tid4k, 'session reopened back at 1080p');
    final at1080 = luminanceProcessor.framesProcessed.value;
    await _expectFramesFlow(after: at1080, stage: 'back at 1080p');
    expect(cameraStore.errorMessage.value, isNull);

    cameraStore.clearFrameProcessor();
    return true;
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
    expect(cameraStore.isRecording.value, isTrue,
        reason: 'recording started (error=${cameraStore.errorMessage.value})');
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
    expect(cameraStore.status.value, CameraStatus.running,
        reason: 'app survived the system-gallery mirror');
  }
}
