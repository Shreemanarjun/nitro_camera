// On-device 4K (UHD) switch regression test.
//
// USER REPORT (iOS): switching to 4K gives NO PREVIEW. This suite proves the
// preview with hard evidence: it asserts real frames keep flowing through a
// frame processor after the 4K reopen (status alone can read "running" while
// the stream is dead), and that the RESOLVED session state actually reports a
// 4K stream — format negotiation, not just the requested numbers.
//
//   cd example && flutter test integration_test/resolution_4k_test.dart -d <device>
// (or build with -t and launch standalone; results in syslog).

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

Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> bootApp(WidgetTester tester) async {
  _ensureRuntime();
  await tester.pumpWidget(
    const MaterialApp(debugShowCheckedModeBanner: false, home: CameraScreen()),
  );
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
      reason: 'CAMERA permission granted (accept the system dialog)',
    );
  }
  await pumpUntil(
    tester,
    () =>
        cameraStore.status.value == CameraStatus.running &&
        (cameraStore.activeController.value?.isInitialized ?? false),
    timeout: const Duration(seconds: 10),
    reason: 'camera preview running with a published controller after boot',
  );
}

/// Waits for [luminanceProcessor.framesProcessed] to advance past [after],
/// proving the native stream is alive (the CPU frame path shares
/// captureOutput with the preview texture path).
Future<void> expectFramesFlow(
  WidgetTester tester, {
  required int after,
  required String stage,
}) async {
  await pumpUntil(
    tester,
    () => luminanceProcessor.framesProcessed.value > after,
    timeout: const Duration(seconds: 15),
    reason: 'frames flowing $stage (framesProcessed stuck at '
        '${luminanceProcessor.framesProcessed.value})',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('4K switch keeps a LIVE preview and reports a real 4K stream',
      semanticsEnabled: false, (tester) async {
    await bootApp(tester);
    if (!cameraStore.supports4K.value) {
      markTestSkipped('active sensor advertises no 4K format');
      return;
    }

    // Prove frames flow at the boot resolution first.
    cameraStore.setFrameProcessor(luminanceProcessor);
    await expectFramesFlow(tester, after: 0, stage: 'at boot (1080p)');

    // Switch to 4K.
    final beforeTid = cameraStore.activeTextureId.value;
    cameraStore.setResolution(3840, 2160);
    await pumpUntil(
      tester,
      () =>
          cameraStore.status.value == CameraStatus.running &&
          cameraStore.activeTextureId.value != beforeTid &&
          (cameraStore.activeController.value?.isInitialized ?? false),
      timeout: const Duration(seconds: 20),
      reason: 'session reopened at 4K',
    );
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'switching to 4K must not surface an error');

    // THE regression assertion: frames must actually flow at 4K.
    final at4kStart = luminanceProcessor.framesProcessed.value;
    await expectFramesFlow(tester, after: at4kStart, stage: 'after 4K switch');

    // Correct-info assertion: the RESOLVED stream really is 4K (long edge
    // >= 3840), not just the requested label. streamWidth/Height are
    // portrait-swapped on iOS, so compare the long edge.
    final state = cameraStore.sessionState();
    expect(state, isNotNull);
    final longEdge =
        state!.width > state.height ? state.width : state.height;
    debugPrint('[4K] resolved stream ${state.width}x${state.height} '
        '@${state.fps} running=${state.running}');
    expect(state.running, isTrue);
    expect(longEdge, greaterThanOrEqualTo(3840),
        reason: 'requested 4K but the resolved stream is '
            '${state.width}x${state.height} — format negotiation picked a '
            'non-4K format (UI would show wrong info)');

    // And the store's own UI label agrees with reality.
    expect(cameraStore.resolutionLabel.value, '4K');

    // Sustained streaming (not just one frame after reopen).
    final sustainStart = luminanceProcessor.framesProcessed.value;
    await pumpFor(tester, const Duration(seconds: 2));
    expect(luminanceProcessor.framesProcessed.value, greaterThan(sustainStart),
        reason: '4K stream died after the first frames');

    // Back to 1080p — preview must survive the round-trip.
    final tid4k = cameraStore.activeTextureId.value;
    cameraStore.setResolution(1920, 1080);
    await pumpUntil(
      tester,
      () =>
          cameraStore.status.value == CameraStatus.running &&
          cameraStore.activeTextureId.value != tid4k,
      timeout: const Duration(seconds: 20),
      reason: 'session reopened back at 1080p',
    );
    final at1080 = luminanceProcessor.framesProcessed.value;
    await expectFramesFlow(tester, after: at1080, stage: 'back at 1080p');
    expect(cameraStore.errorMessage.value, isNull);

    cameraStore.clearFrameProcessor();
  });
}
