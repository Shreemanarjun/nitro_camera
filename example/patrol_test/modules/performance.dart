import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import 'module.dart';

/// Performance budgets — the Patrol port of the legacy capture-latency suite
/// plus regression tripwires for the perf-plan fixes (device-enum cache,
/// setter dispatch). Budgets are deliberately generous: they catch STUCK or
/// order-of-magnitude regressions, not scheduler jitter.
final class Performance extends Module {
  Performance(super.$);

  CameraController get _ctrl => cameraStore.activeController.value!;

  /// Awaits [run] while KEEPING FRAMES PUMPING, failing with [label] if it
  /// does not complete within [deadline]. Returns (result, elapsed).
  Future<(T, Duration)> timed<T>(
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
          'the call is STUCK (error=${cameraStore.errorMessage.value})',
        );
      }
      await $.tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    sw.stop();
    if (error != null) {
      Error.throwWithStackTrace(error!, stack!);
    }
    return (result as T, sw.elapsed);
  }

  /// Photo capture returns within [budget], [rounds] times in a row.
  Future<void> photoLatency({
    int rounds = 3,
    Duration budget = const Duration(seconds: 4),
  }) async {
    await pumpFor(const Duration(seconds: 1)); // AE/AF settle once
    for (var i = 1; i <= rounds; i++) {
      final (result, elapsed) = await timed(
        () => _ctrl.takePhotoWithOptions(
          const PhotoCaptureOptions(
            flash: FlashMode.off,
            quality: QualityPrioritization.balanced,
          ),
        ),
        deadline: const Duration(seconds: 15),
        label: 'photo #$i',
      );
      final f = File(result.path);
      expect(f.existsSync(), isTrue, reason: 'photo #$i file missing');
      expect(f.lengthSync(), greaterThan(0));
      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
      expect(
        elapsed,
        lessThan(budget),
        reason: 'photo #$i took ${elapsed.inMilliseconds}ms',
      );
      f.deleteSync();
      await pumpFor(const Duration(milliseconds: 300));
    }
  }

  /// Preview snapshot returns within [budget].
  Future<void> snapshotLatency({
    Duration budget = const Duration(seconds: 4),
  }) async {
    final (result, elapsed) = await timed(
      () => _ctrl.takeSnapshot(),
      deadline: const Duration(seconds: 15),
      label: 'snapshot',
    );
    final f = File(result.path);
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), greaterThan(0));
    expect(
      elapsed,
      lessThan(budget),
      reason: 'snapshot took ${elapsed.inMilliseconds}ms',
    );
    f.deleteSync();
  }

  /// 3 s video: start < 4 s, stop finalises a valid file in < 3 s.
  Future<void> videoLatency() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/perf_video_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final (_, startElapsed) = await timed(
      () => _ctrl.startRecording(path),
      deadline: const Duration(seconds: 10),
      label: 'video start',
    );
    expect(
      startElapsed,
      lessThan(const Duration(seconds: 4)),
      reason: 'start took ${startElapsed.inMilliseconds}ms',
    );

    await pumpFor(const Duration(seconds: 3));

    final (rec, stopElapsed) = await timed(
      () => _ctrl.stopRecording(),
      deadline: const Duration(seconds: 12),
      label: 'video stop',
    );
    expect(
      stopElapsed,
      lessThan(const Duration(seconds: 3)),
      reason: 'stop took ${stopElapsed.inMilliseconds}ms',
    );
    final f = File(rec.path);
    expect(f.existsSync(), isTrue);
    expect(rec.fileSize, greaterThan(0));
    expect(
      rec.durationMs,
      greaterThan(2000),
      reason: 'recorded ~3s but durationMs=${rec.durationMs}',
    );
    f.deleteSync();
  }

  /// Photo immediately after a video stop must not get stuck.
  Future<void> backToBackCapture() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/perf_b2b_${DateTime.now().millisecondsSinceEpoch}.mp4';
    await timed(
      () => _ctrl.startRecording(path),
      deadline: const Duration(seconds: 10),
      label: 'b2b video start',
    );
    await pumpFor(const Duration(seconds: 1));
    final (rec, _) = await timed(
      () => _ctrl.stopRecording(),
      deadline: const Duration(seconds: 12),
      label: 'b2b video stop',
    );
    File(rec.path).deleteSync();

    final (photo, elapsed) = await timed(
      () => _ctrl.takePhotoWithOptions(const PhotoCaptureOptions()),
      deadline: const Duration(seconds: 15),
      label: 'photo after video',
    );
    expect(File(photo.path).existsSync(), isTrue);
    expect(elapsed, lessThan(const Duration(seconds: 4)));
    File(photo.path).deleteSync();
  }

  /// Warm device enumeration must be near-instant (per-process cache — the
  /// 2.76 s cold walk was the measured perf-plan regression). Boot already
  /// warmed the cache; three consecutive calls must each stay under [budget].
  Future<void> deviceEnumWarm({
    Duration budget = const Duration(milliseconds: 500),
  }) async {
    for (var i = 1; i <= 3; i++) {
      final sw = Stopwatch()..start();
      final devices = await CameraController.getAvailableCameraDevices();
      sw.stop();
      expect(devices, isNotEmpty);
      expect(
        sw.elapsed,
        lessThan(budget),
        reason:
            'warm enumeration #$i took ${sw.elapsedMilliseconds}ms '
            '(cache regression — perf plan §1.1)',
      );
    }
  }

  /// Every live setter must RETURN fast (fire-and-forget contract). This is
  /// the tripwire for the 320 ms inline-setHdr class of regression: the FFI
  /// call must never block on device reconfiguration.
  Future<void> setterLatency({
    Duration budget = const Duration(milliseconds: 100),
  }) async {
    final c = _ctrl;
    final setters = <String, void Function()>{
      'setZoom': () => c.setZoom(1.5),
      'setExposure': () => c.setExposure(0.3),
      'setFlash': () => c.setFlash(FlashMode.auto),
      'setWhiteBalance': () => c.setWhiteBalance(5000),
      'setHdr': () => c.setHdr(enabled: true),
      'setLowLightBoost': () => c.setLowLightBoost(enabled: false),
      'setVideoStabilization': () =>
          c.setVideoStabilization(VideoStabilizationMode.off),
      'setSamplingRate': () => c.setSamplingRate(1),
      'focus': () => c.focus(0.5, 0.5),
    };
    for (final entry in setters.entries) {
      // Best of 3 — a single call can eat a scheduler hiccup; a REGRESSION
      // (inline native reconfigure) is slow on every call.
      var best = const Duration(days: 1);
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        entry.value();
        sw.stop();
        if (sw.elapsed < best) best = sw.elapsed;
        await pumpFor(const Duration(milliseconds: 100));
      }
      expect(
        best,
        lessThan(budget),
        reason:
            '${entry.key} blocked for ${best.inMilliseconds}ms — '
            'live setters must dispatch, not block (perf plan §1.2)',
      );
    }
    // Restore defaults + settle; the batch path must also return promptly.
    final base = c.configuration!;
    final sw = Stopwatch()..start();
    await c.configure(
      base.copyWith(
        zoom: 1.0,
        exposure: 0.0,
        flash: FlashMode.off,
        whiteBalanceKelvin: 0,
        videoHdr: false,
      ),
    );
    sw.stop();
    expect(
      sw.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'atomic configure() took ${sw.elapsedMilliseconds}ms',
    );
    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.errorMessage.value, isNull);
  }
}
