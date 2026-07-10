// On-device camera lifecycle integration tests.
//
// Run on a connected device:
//   cd example && flutter test integration_test/camera_lifecycle_test.dart -d <serial>
//
// Every test boots through the shared harness, which ASKS for camera/mic
// permission via the app's own request flow when missing — accept the system
// dialog on the device (the wait allows 90s). A grant from an earlier run
// PERSISTS across `-r` reinstalls, so re-run
// `integration_test/support/reset_permissions.sh <serial>` to see the prompt
// again. The Patrol suite (patrol_test/) starts each test revoked (orchestrator
// clearPackageData) and accepts the dialogs natively.
//
// The tests drive the real example app (CameraScreen + cameraStore) against
// the real camera HAL, covering the session-lifecycle discipline:
// boot-to-preview, rapid device switching, scanner/native-detector handover
// and resolution reopen.


import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:nitro_camera_example/features/camera/processors/luminance_processor.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import 'support/harness.dart';


void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Known real-device environment flake (observed on ColorOS/CPH2447): the OS
  // flips the platform semantics-enabled state mid-test (its accessibility
  // bridge toggles around camera UX changes), so the framework binding
  // acquires a SemanticsHandle DURING a test and flutter_test's end-of-test
  // verifier fails whichever test the event happened to land in with
  // "A SemanticsHandle was active at the end of the test". Nothing in the
  // app under test creates semantics handles (semanticsEnabled: false below),
  // so that specific verifier failure is filtered here; every other exception
  // still fails the test normally.
  installSemanticsFlakeFilter();

  // semanticsEnabled: false on every test: the default per-test SemanticsHandle
  // races the pipeline owner's asynchronous semantics detach on real devices,
  // randomly failing tests with "A SemanticsHandle was active at the end of
  // the test". These tests assert camera behavior, not accessibility.
  testWidgets('1. app boots to a running camera preview',
      semanticsEnabled: false, (tester) async {
    await bootApp(tester);

    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.activeController.value, isNotNull);
    expect(cameraStore.activeTextureId.value, isNotNull);
    expect(cameraStore.activeTextureId.value, isNot(0),
        reason: 'textureId 0 means the native open failed');
    expect(cameraStore.errorMessage.value, isNull);
  });

  testWidgets('2. survives rapid device switching (6 toggles, 1s gaps)',
      semanticsEnabled: false, (tester) async {
    await bootApp(tester);
    if (cameraStore.devices.value.length < 2) {
      markTestSkipped('device exposes fewer than 2 cameras');
      return;
    }

    for (var i = 1; i <= 6; i++) {
      final beforeTid = cameraStore.activeTextureId.value;
      cameraStore.toggleCamera();
      await pumpUntil(
        tester,
        () =>
            cameraStore.status.value == CameraStatus.running &&
            cameraStore.activeTextureId.value != beforeTid,
        timeout: const Duration(seconds: 15),
        reason: 'preview running on the new device after toggle $i',
      );
      expect(cameraStore.errorMessage.value, isNull,
          reason: 'toggle $i must not surface an error');
      await pumpFor(tester, const Duration(seconds: 1));
    }

    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  });

  testWidgets('3. custom frame processor receives frames and survives a '
      'SCANNER round-trip', semanticsEnabled: false, (tester) async {
    await bootApp(tester);

    // Install the demo LUMA processor (user-pluggable FrameProcessor).
    cameraStore.setFrameProcessor(luminanceProcessor);
    expect(cameraStore.frameProcessor.value, isNotNull);
    // Condition-based, not a fixed sleep: first-frame delivery has to cross
    // enableFrameProcessing → repeating-request rebuild → FFI stream, and a
    // late session reapply may re-adopt the processor — a fixed pump races
    // that pipeline and flakes. Gate on the FRAME COUNTER, not the luminance
    // value: a covered lens / black scene legitimately reads 0.0, and this
    // test's claim is "frames are delivered", not "the scene is bright".
    await pumpUntil(
      tester,
      () => luminanceProcessor.framesProcessed.value > 0,
      timeout: const Duration(seconds: 15),
      reason: 'frames flowed through the custom processor '
          '(framesProcessed stayed 0 — native delivery gap, not scene-dependent)',
    );
    expect(luminanceProcessor.attached.value, isTrue,
        reason: 'processor is adopted by the live session');
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'enabling a custom processor must not error');

    // Enter SCANNER: the Dart scanner and the custom processor coexist as
    // listeners on the same broadcast frame stream.
    await cameraStore.setMode('SCANNER');
    await pumpFor(tester, const Duration(seconds: 2));
    expect(cameraStore.mode.value, 'SCANNER');
    expect(cameraStore.frameProcessor.value, isNotNull,
        reason: 'custom processor stays installed during SCANNER');
    expect(cameraStore.status.value, CameraStatus.running);

    // Leave SCANNER: the processor keeps running, with no error.
    await cameraStore.setMode('PHOTO');
    await pumpFor(tester, const Duration(seconds: 2));
    expect(cameraStore.mode.value, 'PHOTO');
    expect(cameraStore.frameProcessor.value, isNotNull);
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);

    // LENS CHANGE with the processor installed (user repro: "changing lens
    // with luminance on stuck the app"): the store must re-attach the
    // processor to the fresh session and frames must keep flowing — even on
    // lenses whose HAL starves the YUV stream beside the pre-wired recorder
    // surface (the native starvation watchdog rebuilds without it).
    if (cameraStore.devices.value.length > 1) {
      final beforeTid = cameraStore.activeTextureId.value;
      final beforeFrames = luminanceProcessor.framesProcessed.value;
      cameraStore.toggleCamera();
      await pumpUntil(
        tester,
        () =>
            cameraStore.status.value == CameraStatus.running &&
            cameraStore.activeTextureId.value != beforeTid,
        timeout: const Duration(seconds: 15),
        reason: 'preview running on the new device with the processor installed',
      );
      await pumpUntil(
        tester,
        () => luminanceProcessor.framesProcessed.value > beforeFrames,
        timeout: const Duration(seconds: 15),
        reason: 'frames keep flowing through the processor after a lens change',
      );
      expect(luminanceProcessor.attached.value, isTrue,
          reason: 'processor re-adopted by the new session');
      expect(cameraStore.errorMessage.value, isNull,
          reason: 'a lens change with an active processor must not error');
    }

    // Cleanup for the following tests.
    cameraStore.clearFrameProcessor();
    expect(luminanceProcessor.attached.value, isFalse);
    await pumpFor(tester, const Duration(milliseconds: 500));
  });

  testWidgets('4. resolution change 1080p -> 720p -> 1080p survives',
      semanticsEnabled: false, (tester) async {
    await bootApp(tester);

    Future<void> changeRes(int w, int h) async {
      final beforeTid = cameraStore.activeTextureId.value;
      cameraStore.setResolution(w, h);
      await pumpUntil(
        tester,
        () =>
            cameraStore.status.value == CameraStatus.running &&
            cameraStore.activeTextureId.value != beforeTid,
        timeout: const Duration(seconds: 15),
        reason: 'session reopened at ${w}x$h',
      );
      expect(cameraStore.errorMessage.value, isNull,
          reason: 'switching to ${w}x$h must not surface an error');
      await pumpFor(tester, const Duration(seconds: 1));
    }

    expect(cameraStore.width.value, 1920,
        reason: 'store defaults to 1080p before the round-trip');
    await changeRes(1280, 720);
    await changeRes(1920, 1080);

    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  });
}
