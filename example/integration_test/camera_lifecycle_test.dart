// On-device camera lifecycle integration tests.
//
// Run on a connected device (camera + mic permission must be granted first):
//   adb shell pm grant dev.shreeman.nitro_camera_example android.permission.CAMERA
//   adb shell pm grant dev.shreeman.nitro_camera_example android.permission.RECORD_AUDIO
//   cd example && flutter test integration_test/camera_lifecycle_test.dart -d <serial>
//
// The tests drive the real example app (CameraScreen + cameraStore) against
// the real camera HAL, covering the session-lifecycle discipline:
// boot-to-preview, rapid device switching, scanner/native-detector handover
// and resolution reopen.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nitro/nitro.dart';

import 'package:nitro_camera_example/features/camera/processors/luminance_processor.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/camera_screen.dart';

bool _runtimeInitialized = false;

/// Mirrors `main()`'s one-time runtime setup (safe to call once per process).
void _ensureRuntime() {
  if (_runtimeInitialized) return;
  _runtimeInitialized = true;
  MediaKit.ensureInitialized();
  NitroConfig.instance.enable(
    slowCallThresholdMs: 200,
    level: NitroLogLevel.verbose,
  );
  NitroRuntime.init(isolatePoolSize: Platform.numberOfProcessors);
}

/// Pumps real frames until [condition] holds, failing after [timeout].
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after ${timeout.inSeconds}s waiting for: $reason '
          '(status=${cameraStore.status.value}, '
          'error=${cameraStore.errorMessage.value})');
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

/// Lets the app run (real time + frames) for [duration].
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Mounts the example app (idempotent across tests — the camera keeps running
/// between testWidgets bodies) and waits for a live preview session.
Future<void> bootApp(WidgetTester tester) async {
  _ensureRuntime();
  await tester.pumpWidget(
    const MaterialApp(debugShowCheckedModeBanner: false, home: CameraScreen()),
  );
  // Some OEMs (ColorOS) drop adb-granted runtime permissions on every
  // reinstall and block `pm grant` from shell. When the permission is
  // missing, request it through the app's own flow — the system dialog can
  // then be accepted manually or by a host-side watcher that taps "Allow"
  // (e.g. via `uiautomator dump` + `input tap`).
  await pumpUntil(
    tester,
    () => cameraStore.cameraPermission.value != 0,
    timeout: const Duration(seconds: 5),
    reason: 'camera permission status resolved',
  );
  if (cameraStore.cameraPermission.value != 1) {
    unawaited(cameraStore.grantPermission());
    await pumpUntil(
      tester,
      () => cameraStore.cameraPermission.value == 1,
      timeout: const Duration(seconds: 90),
      reason: 'CAMERA permission granted (accept the system dialog on the '
          'device, or pre-grant with: adb install -r -g <test-apk>)',
    );
  }
  await pumpUntil(
    tester,
    () => cameraStore.status.value == CameraStatus.running,
    timeout: const Duration(seconds: 10),
    reason: 'camera preview running after app boot',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1. app boots to a running camera preview', (tester) async {
    await bootApp(tester);

    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.activeController.value, isNotNull);
    expect(cameraStore.activeTextureId.value, isNotNull);
    expect(cameraStore.activeTextureId.value, isNot(0),
        reason: 'textureId 0 means the native open failed');
    expect(cameraStore.errorMessage.value, isNull);
  });

  testWidgets('2. survives rapid device switching (6 toggles, 1s gaps)',
      (tester) async {
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
      'SCANNER round-trip', (tester) async {
    await bootApp(tester);

    // Install the demo LUMA processor (user-pluggable FrameProcessor).
    cameraStore.setFrameProcessor(luminanceProcessor);
    await pumpFor(tester, const Duration(seconds: 3));
    expect(cameraStore.frameProcessor.value, isNotNull);
    expect(luminanceProcessor.attached.value, isTrue,
        reason: 'processor is adopted by the live session');
    expect(luminanceProcessor.luminance.value, greaterThan(0.0),
        reason: 'frames flowed through the custom processor');
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

    // Cleanup for the following tests.
    cameraStore.clearFrameProcessor();
    expect(luminanceProcessor.attached.value, isFalse);
    await pumpFor(tester, const Duration(milliseconds: 500));
  });

  testWidgets('4. resolution change 1080p -> 720p -> 1080p survives',
      (tester) async {
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
