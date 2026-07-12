// On-device photo / video capture latency integration tests.
//
// Run on a connected device:
//   cd example && flutter test integration_test/capture_latency_test.dart -d <device>
//
// Every test boots through the shared harness, which ASKS for camera/mic
// permission via the app's own request flow when missing — accept the system
// dialog on the device (the wait allows 90s). A grant persists across `-r`
// reinstalls; run `integration_test/support/reset_permissions.sh <serial>` to
// force the prompt again. The Patrol suite accepts the dialogs natively.
//
// The tests drive the real example app (CameraScreen + cameraStore) against
// the real capture stack and assert that captures RETURN — and return fast:
//   * still photo (balanced quality, flash off)  < 4s
//   * preview snapshot                            < 4s
//   * video: start < 4s, 3s clip, stop            < 3s
// A hang (the "capture gets stuck" bug) fails via the explicit timeouts
// instead of stalling the whole suite.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import 'support/harness.dart';

/// Awaits [run] while KEEPING FRAMES PUMPING, failing with [label] if it does
/// not complete within [deadline]. Returns (result, elapsed).
Future<(T, Duration)> timedCapture<T>(
  WidgetTester tester,
  Future<T> Function() run, {
  required Duration deadline,
  required String label,
}) async {
  final sw = Stopwatch()..start();
  final future = run();
  T? result;
  Object? error;
  StackTrace? stack;
  var done = false;
  unawaited(
    future.then(
      (r) {
        result = r;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  while (!done) {
    if (sw.elapsed > deadline) {
      fail(
        '$label did not complete within ${deadline.inMilliseconds}ms — '
        'the capture is STUCK (error=${cameraStore.errorMessage.value})',
      );
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  sw.stop();
  if (error != null) {
    Error.throwWithStackTrace(
      TestFailure('$label threw after ${sw.elapsedMilliseconds}ms: $error'),
      stack!,
    );
  }
  debugPrint('[LATENCY] $label: ${sw.elapsedMilliseconds}ms');
  return (result as T, sw.elapsed);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // See camera_lifecycle_test.dart: filter the platform-driven SemanticsHandle
  // flake; every other exception still fails the test normally.
  installSemanticsFlakeFilter();

  testWidgets(
    '1. photo capture returns within 4s (x3, flash off, balanced)',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final ctrl = cameraStore.activeController.value!;
      // Let AE/AF settle once so the timings measure capture, not first-boot
      // convergence.
      await pumpFor(tester, const Duration(seconds: 1));

      for (var i = 1; i <= 3; i++) {
        final (result, elapsed) = await timedCapture(
          tester,
          () => ctrl.takePhotoWithOptions(
            const PhotoCaptureOptions(
              flash: FlashMode.off,
              quality: QualityPrioritization.balanced,
            ),
          ),
          deadline: const Duration(seconds: 15),
          label: 'photo #$i',
        );
        expect(result.path, isNotEmpty, reason: 'photo #$i returned no path');
        final f = File(result.path);
        expect(f.existsSync(), isTrue, reason: 'photo #$i file missing');
        expect(f.lengthSync(), greaterThan(0), reason: 'photo #$i file empty');
        expect(result.width, greaterThan(0));
        expect(result.height, greaterThan(0));
        expect(
          elapsed.inMilliseconds,
          lessThan(4000),
          reason: 'photo #$i took ${elapsed.inMilliseconds}ms (limit 4000ms)',
        );
        f.deleteSync();
        await pumpFor(tester, const Duration(milliseconds: 300));
      }
    },
  );

  testWidgets('2. snapshot returns within 4s', semanticsEnabled: false, (
    tester,
  ) async {
    await bootApp(tester);
    final ctrl = cameraStore.activeController.value!;

    final (result, elapsed) = await timedCapture(
      tester,
      () => ctrl.takeSnapshot(),
      deadline: const Duration(seconds: 15),
      label: 'snapshot',
    );
    expect(File(result.path).existsSync(), isTrue);
    expect(File(result.path).lengthSync(), greaterThan(0));
    expect(
      elapsed.inMilliseconds,
      lessThan(4000),
      reason: 'snapshot took ${elapsed.inMilliseconds}ms (limit 4000ms)',
    );
    File(result.path).deleteSync();
  });

  testWidgets(
    '3. 3s video: start < 4s, stop returns a valid file in < 3s',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final ctrl = cameraStore.activeController.value!;

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/itest_video_${DateTime.now().millisecondsSinceEpoch}.mp4';

      final (_, startElapsed) = await timedCapture(
        tester,
        () => ctrl.startRecording(path),
        deadline: const Duration(seconds: 10),
        label: 'video start',
      );
      expect(
        startElapsed.inMilliseconds,
        lessThan(4000),
        reason:
            'startRecording took ${startElapsed.inMilliseconds}ms '
            '(limit 4000ms)',
      );

      await pumpFor(tester, const Duration(seconds: 3));

      final (result, stopElapsed) = await timedCapture(
        tester,
        () => ctrl.stopRecording(),
        deadline: const Duration(seconds: 12),
        label: 'video stop',
      );
      expect(
        stopElapsed.inMilliseconds,
        lessThan(3000),
        reason:
            'stopRecording took ${stopElapsed.inMilliseconds}ms (limit 3000ms)',
      );
      expect(result.path, isNotEmpty);
      final f = File(result.path);
      expect(f.existsSync(), isTrue, reason: 'recorded file missing');
      expect(f.lengthSync(), greaterThan(0), reason: 'recorded file empty');
      expect(result.fileSize, greaterThan(0));
      expect(
        result.durationMs,
        greaterThan(2000),
        reason: 'a ~3s recording reported ${result.durationMs}ms',
      );
      expect(
        result.width,
        greaterThan(0),
        reason: 'recording metadata must report encoded width',
      );
      expect(
        result.height,
        greaterThan(0),
        reason: 'recording metadata must report encoded height',
      );
      expect(
        result.videoCodec,
        VideoCodec.h264,
        reason: 'default recording codec should be H.264',
      );
      expect(
        result.videoFileType,
        VideoFileType.mp4,
        reason: 'default recording container should be mp4',
      );
      expect(result.reason, RecordingFinishedReason.stopped);
      debugPrint(
        '[LATENCY] video file: ${f.lengthSync()} bytes, '
        '${result.durationMs}ms ${result.width}x${result.height} '
        '${result.videoCodec.name}/${result.videoFileType.name} '
        'reason=${result.reason.name}',
      );
      f.deleteSync();
    },
  );

  testWidgets(
    '4. back-to-back: photo right after video stop stays unstuck',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final ctrl = cameraStore.activeController.value!;

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/itest_video2_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await timedCapture(
        tester,
        () => ctrl.startRecording(path),
        deadline: const Duration(seconds: 10),
        label: 'video2 start',
      );
      await pumpFor(tester, const Duration(seconds: 1));
      final (rec, _) = await timedCapture(
        tester,
        () => ctrl.stopRecording(),
        deadline: const Duration(seconds: 12),
        label: 'video2 stop',
      );
      File(rec.path).deleteSync();

      final (photo, elapsed) = await timedCapture(
        tester,
        () => ctrl.takePhotoWithOptions(const PhotoCaptureOptions()),
        deadline: const Duration(seconds: 15),
        label: 'photo after video',
      );
      expect(File(photo.path).existsSync(), isTrue);
      expect(elapsed.inMilliseconds, lessThan(4000));
      File(photo.path).deleteSync();
    },
  );

  testWidgets(
    '5. STORE-level capture persists without crashing '
    '(regression: Photos-library save aborted the app when '
    'NSPhotoLibraryAddUsageDescription was missing)',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);

      // Photo through the full store path: capture → persist → unawaited
      // Photos-library mirror (Gal.putImage).
      final photosBefore = cameraStore.capturedMedia.value.length;
      await cameraStore.takePhoto();
      await pumpUntil(
        tester,
        () => cameraStore.capturedMedia.value.length > photosBefore,
        timeout: const Duration(seconds: 15),
        reason: 'store photo captured and persisted',
      );
      expect(
        cameraStore.errorMessage.value,
        isNull,
        reason: 'store photo capture must not surface an error',
      );

      // Video through the full store path (the exact flow that crashed):
      // record → stop → persist → unawaited Gal.putVideo.
      final mediaBefore = cameraStore.capturedMedia.value.length;
      await cameraStore.toggleRecording();
      expect(
        cameraStore.isRecording.value,
        isTrue,
        reason: 'recording started (error=${cameraStore.errorMessage.value})',
      );
      await pumpFor(tester, const Duration(seconds: 2));
      await cameraStore.toggleRecording();
      await pumpUntil(
        tester,
        () =>
            !cameraStore.isRecording.value &&
            cameraStore.capturedMedia.value.length > mediaBefore,
        timeout: const Duration(seconds: 15),
        reason: 'recording stopped and persisted to the in-app library',
      );
      expect(cameraStore.errorMessage.value, isNull);

      // Give the fire-and-forget Photos-library mirror time to run: with the
      // usage key missing this is where iOS ABORTED the process (TCC kill —
      // uncatchable, so "no crash for 5s" IS the assertion). With the key
      // present the first run shows the one-time "Add Photos" prompt instead;
      // the save is best-effort either way.
      await pumpFor(tester, const Duration(seconds: 5));
      expect(
        cameraStore.status.value,
        CameraStatus.running,
        reason: 'app survived the system-gallery mirror',
      );
    },
  );
}
