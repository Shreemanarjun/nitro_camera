// Shared on-device test harness — used by BOTH suites:
//  * plain integration_test/ (flutter test integration_test/... — the
//    iOS-runnable mirror), and
//  * patrol_test/ (Patrol modules delegate here with `$.tester`, passing a
//    native permission-grant hook so the system dialogs are accepted via
//    $.platform.mobile.grantPermissionWhenInUse instead of a manual tap).
//
// One-time runtime setup, condition-based pumping against real frames, app
// boot with the permission flow, and the platform-driven SemanticsHandle
// flake filter.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nitro/nitro.dart';
import 'package:nitro_camera/native.dart' show NitroCamera;

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/camera_screen.dart';

bool _runtimeInitialized = false;

/// Mirrors `main()`'s one-time runtime setup (safe to call once per process).
void ensureRuntime() {
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
/// between test bodies) and waits for a live preview session.
///
/// Permission flow:
///  * [grantPermissionNatively] set (Patrol): the app's grant flow is fired
///    and the hook is invoked to accept the system dialog(s) natively —
///    `() async { await $.platform.mobile.grantPermissionWhenInUse(); // CAMERA
///                 await $.platform.mobile.grantPermissionWhenInUse(); // MIC }`.
///    This is the ColorOS answer: adb-granted permissions are revoked on
///    reinstall and `pm grant` is blocked, so the dialog is walked for real.
///  * hook absent (plain integration_test): the system dialog must be
///    accepted manually on the device — the wait allows 90 s for that. If the
///    permission was granted by an earlier run it PERSISTS across `-r`
///    reinstalls, so the flow is skipped; run `support/reset_permissions.sh`
///    first to force the prompt again.
Future<void> bootApp(
  WidgetTester tester, {
  Future<void> Function()? grantPermissionNatively,
  bool alwaysRequest = false,
}) async {
  ensureRuntime();
  await tester.pumpWidget(
    const MaterialApp(debugShowCheckedModeBanner: false, home: CameraScreen()),
  );
  const granted = 1; // PermissionStatus.granted
  await pumpFor(tester, const Duration(milliseconds: 200)); // mount the screen
  final alreadyGranted =
      NitroCamera.instance.getCameraPermissionStatus() == granted;
  // [alwaysRequest] (Patrol): ALWAYS run the request + native-grant flow, even
  // when the OS already reports granted, so the grant is DETERMINISTIC and not
  // dependent on retained state. This is safe: the native
  // requestCameraPermission short-circuits to granted (no dialog) when already
  // held, and the accept loop is guarded by isPermissionDialogVisible so it
  // no-ops when no dialog appears. Without it (plain integration_test): only
  // run the flow when NOT already granted, since nothing can accept a dialog
  // automatically. The native query returns granted(1)/denied(2) only — never
  // notDetermined(0) — so gate on granted, not "!= 0".
  debugPrint(alreadyGranted
      ? 'NitroCamera test: CAMERA already granted (alwaysRequest=$alwaysRequest).'
      : 'NitroCamera test: CAMERA not granted — running the request flow.');
  if (alwaysRequest || !alreadyGranted) {
    // grantPermission() requests CAMERA then MICROPHONE (recording tests need
    // mic) and only publishes cameraPermission after both — so accepting both
    // native dialogs is what flips it to granted.
    final granting = cameraStore.grantPermission();
    if (grantPermissionNatively != null) {
      await grantPermissionNatively();
      await granting;
      await pumpUntil(
        tester,
        () => cameraStore.cameraPermission.value == granted,
        reason: 'CAMERA (+ MIC) permission granted through the native dialogs',
      );
    } else {
      unawaited(granting);
      await pumpUntil(
        tester,
        () => cameraStore.cameraPermission.value == granted,
        timeout: const Duration(seconds: 90),
        reason: 'CAMERA + MIC permission granted (accept BOTH system dialogs '
            'on the device, or pre-grant with: adb install -r -g <test-apk>)',
      );
    }
  }
  // Gate on the PUBLISHED controller too, not just the status signal: during
  // a session settle/swap the status can read `running` while the fresh
  // controller (and its reapply pass) hasn't landed yet.
  await pumpUntil(
    tester,
    () =>
        cameraStore.status.value == CameraStatus.running &&
        (cameraStore.activeController.value?.isInitialized ?? false),
    timeout: const Duration(seconds: 10),
    reason: 'camera preview running with a published controller after boot',
  );
}

bool _flakeFilterInstalled = false;

/// Filters the ColorOS-driven "A SemanticsHandle was active at the end of the
/// test" flake (the OS toggles the accessibility bridge mid-test); every other
/// exception still fails normally. Idempotent — safe from both suite styles.
void installSemanticsFlakeFilter() {
  if (_flakeFilterInstalled) return;
  _flakeFilterInstalled = true;
  final defaultReporter = reportTestException;
  reportTestException = (details, testDescription) {
    final e = details.exception;
    if (e is FlutterError &&
        e.message.startsWith('A SemanticsHandle was active')) {
      debugPrint(
          'Ignored platform-driven SemanticsHandle flake in "$testDescription"');
      return;
    }
    defaultReporter(details, testDescription);
  };
}
