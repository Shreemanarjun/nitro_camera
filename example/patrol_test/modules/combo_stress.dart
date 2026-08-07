import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart'
    show
        expect,
        fail,
        greaterThan,
        greaterThanOrEqualTo,
        isA,
        isEmpty,
        isFalse,
        isNotNull,
        isNull,
        isTrue,
        lessThan,
        lessThanOrEqualTo;
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import '../support/frame_stats.dart';
import '../support/mp4_probe.dart';
import 'module.dart';

/// Sentinel that wins the [ComboStress._race] when a call blows its deadline.
final Object _deadlineExpired = Object();

/// COMBINATION stress + recorder-state-machine module.
///
/// The single-feature suites each drive one recording, one reconfigure or one
/// illegal call in isolation, so state that ACCUMULATES across operations —
/// recorder objects, encoder buffers, half-torn sessions — never shows up.
/// Every method here runs several features against the same live session and
/// asserts observable outcomes (container validity, latency growth, frame
/// continuity, state flags), never merely "nothing threw".
///
/// Android defects these methods are built to expose:
///  * `CameraSession.onAppStop` / session close (CameraSession.kt:336) closes
///    the camera and capture session WITHOUT stopping an in-flight recording —
///    the MP4 never gets its `moov` atom, so the clip is unplayable while the
///    plugin's own `RecordingResult` still looks healthy.
///  * `startPreview()` (CameraSession.kt:449) is an unlocked
///    check-then-`createCaptureSession` reachable from three threads — a
///    reconfigure storm can build two sessions.
///  * The recorder limit callbacks (CameraSession.kt:1030-1049) re-enter
///    `MediaRecorder` from its own callback thread.
///  * `VideoOutput` start failures leave `isRecording = true` plus an orphan
///    file (outputs/VideoOutput.kt:167).
///  * Dart: nothing clears `CameraController._isRecording` when the NATIVE
///    side auto-stops a recording, so app state desyncs from the recorder.
final class ComboStress extends Module {
  ComboStress(super.$);

  /// The live session controller. Re-read after every reopen — the example app
  /// builds a BRAND NEW [CameraController] each time `CameraView` reconfigures.
  CameraController get _ctrl => cameraStore.activeController.value!;

  // ── Deadlines ───────────────────────────────────────────────────────────────

  /// Races [future] against [deadline] while KEEPING REAL FRAMES PUMPING, so a
  /// wedged native call is reported by our own descriptive failure rather than
  /// by Patrol timing out the whole test. Returns [_deadlineExpired] when the
  /// deadline won.
  Future<Object?> _race(Future<Object?> future, Duration deadline) async {
    var settled = false;
    unawaited(() async {
      while (!settled) {
        await $.tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }());
    try {
      return await Future.any<Object?>([
        future,
        Future<Object?>.delayed(deadline, () => _deadlineExpired),
      ]);
    } finally {
      settled = true;
    }
  }

  /// Awaits a void call, failing with [label] if it does not return in time.
  Future<void> _awaitWithin(
    Future<void> future, {
    required Duration deadline,
    required String label,
  }) async {
    final raced = await _race(future.then<Object?>((_) => null), deadline);
    if (identical(raced, _deadlineExpired)) {
      fail(
        '$label did not return within ${deadline.inMilliseconds}ms — the call '
        'is STUCK (store error=${cameraStore.errorMessage.value})',
      );
    }
  }

  /// Awaits a value-returning call under the same deadline discipline.
  Future<T> _resultWithin<T extends Object>(
    Future<T> future, {
    required Duration deadline,
    required String label,
  }) async {
    final raced = await _race(future.then<Object?>((v) => v), deadline);
    if (identical(raced, _deadlineExpired)) {
      fail(
        '$label did not return within ${deadline.inMilliseconds}ms — the call '
        'is STUCK (store error=${cameraStore.errorMessage.value})',
      );
    }
    return raced! as T;
  }

  /// Runs an ILLEGAL recorder transition.
  ///
  /// Returns the typed exception it raised, or null when the call was a
  /// tolerated no-op. FAILS when the call hangs past [deadline] (a wedged
  /// state machine) or throws something outside the sealed [CameraException]
  /// hierarchy (an untyped crash leaking out of the plugin).
  Future<CameraException?> _illegal(
    String label,
    Future<Object?> Function() call, {
    Duration deadline = const Duration(seconds: 10),
  }) async {
    Object? thrown;
    Object? value;
    final settled = Future<Object?>.sync(call).then<Object?>(
      (v) {
        value = v;
        return null;
      },
      onError: (Object e) {
        thrown = e;
        return null;
      },
    );
    final raced = await _race(settled, deadline);
    if (identical(raced, _deadlineExpired)) {
      fail(
        '$label HUNG for over ${deadline.inSeconds}s — the recorder state '
        'machine is wedged (store error=${cameraStore.errorMessage.value})',
      );
    }
    final error = thrown;
    if (error != null) {
      expect(
        error,
        isA<CameraException>(),
        reason:
            '$label threw ${error.runtimeType} ($error) — an illegal '
            'transition must be a no-op or a TYPED CameraException',
      );
      return error as CameraException;
    }
    final result = value;
    if (result is RecordingResult) _deleteQuietly(result.path);
    return null;
  }

  // ── Small shared helpers ────────────────────────────────────────────────────

  void _deleteQuietly(String path) {
    if (path.isEmpty) return;
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  /// Pumps real frames until [condition] holds or [timeout] elapses, sampling
  /// [onPoll] every tick. Returns whether the condition held — the NON-failing
  /// counterpart of [pumpUntil], so the caller attaches a defect-specific
  /// reason to the failure instead of a generic pump timeout.
  Future<bool> _settles(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
    void Function()? onPoll,
  }) async {
    final sw = Stopwatch()..start();
    while (true) {
      onPoll?.call();
      if (condition()) return true;
      if (sw.elapsed >= timeout) return false;
      await pumpFor(const Duration(milliseconds: 100));
    }
  }

  /// Streams frames for [window] and returns aggregate stats (same idiom as
  /// `Preview.collectFor`: warm up, collect, drop frame processing again).
  Future<FrameStreamReport> _collectFrames(
    Duration window, {
    Duration warmup = const Duration(milliseconds: 600),
  }) async {
    final c = _ctrl;
    c.setFrameProcessing(enabled: true);
    await pumpFor(warmup);
    final collector = FrameStatsCollector()..attach(c.frameStream);
    await pumpFor(window);
    final report = await collector.stop();
    c.setFrameProcessing(enabled: false);
    return report;
  }

  /// Records a [duration] clip on the CURRENT controller, probes the container
  /// and removes the file. The caller asserts on the returned [Mp4Info].
  Future<Mp4Info> _recordProbeAndDelete(
    Duration duration, {
    required String tag,
  }) async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/combo_${tag}_'
        '${DateTime.now().millisecondsSinceEpoch}.mp4';

    await _awaitWithin(
      c.startRecording(path),
      deadline: const Duration(seconds: 15),
      label: '$tag startRecording',
    );
    await pumpFor(duration);
    final rec = await _resultWithin(
      c.stopRecording(),
      deadline: const Duration(seconds: 15),
      label: '$tag stopRecording',
    );

    final file = File(rec.path.isEmpty ? path : rec.path);
    expect(
      file.existsSync(),
      isTrue,
      reason: '$tag: stopRecording reported "${rec.path}" but no file is there',
    );
    final info = probeMp4(file);
    _deleteQuietly(file.path);
    _deleteQuietly(path);
    return info;
  }

  // ── 1. Back-to-back recording cycles ────────────────────────────────────────

  /// [cycles] start/stop cycles on ONE session. Every clip must be playable,
  /// and the session must not degrade across them:
  ///  * start latency on the last cycle must stay inside 2.5x the warm median
  ///    (cycles 1-3) — a recorder that accumulates per-cycle state shows up as
  ///    a monotonically rising start cost;
  ///  * preview FPS after the last cycle must hold at ≥70% of the FPS measured
  ///    before the first (same degradation idiom as
  ///    `Preview.verifyLongStreamStability`);
  ///  * the store carries no error and a fresh clip still records.
  Future<void> backToBackRecordingCycles({int cycles = 10}) async {
    final dir = await getTemporaryDirectory();

    final before = await _collectFrames(const Duration(seconds: 3));
    expect(
      before.frameCount,
      greaterThan(10),
      reason: 'no baseline preview frames before the record cycles ($before)',
    );

    final startMs = <int>[];
    for (var i = 1; i <= cycles; i++) {
      final c = _ctrl;
      final path =
          '${dir.path}/combo_cycle_${i}_'
          '${DateTime.now().millisecondsSinceEpoch}.mp4';

      final sw = Stopwatch()..start();
      await _awaitWithin(
        c.startRecording(path),
        deadline: const Duration(seconds: 15),
        label: 'cycle $i startRecording (latencies so far: $startMs)',
      );
      sw.stop();
      startMs.add(sw.elapsedMilliseconds);
      expect(
        c.isRecording,
        isTrue,
        reason: 'cycle $i: startRecording returned but isRecording is false',
      );

      await pumpFor(const Duration(milliseconds: 1500));

      final rec = await _resultWithin(
        c.stopRecording(),
        deadline: const Duration(seconds: 15),
        label: 'cycle $i stopRecording (latencies so far: $startMs)',
      );
      expect(
        c.isRecording,
        isFalse,
        reason: 'cycle $i: still "recording" after stopRecording returned',
      );

      final file = File(rec.path.isEmpty ? path : rec.path);
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'cycle $i produced no file at "${rec.path}" '
            '(start latencies: $startMs)',
      );
      final info = probeMp4(file);
      expect(
        info.isPlayable,
        isTrue,
        reason:
            'cycle $i wrote an UNPLAYABLE clip — $info. A missing moov means '
            'the recorder was torn down without a finalising stop() '
            '(start latencies: $startMs)',
      );
      expect(
        info.durationMs,
        isNotNull,
        reason: 'cycle $i clip carries no mvhd duration — $info',
      );
      expect(
        info.durationMs!,
        greaterThanOrEqualTo(1200),
        reason:
            'cycle $i recorded ~1500ms but the container says '
            '${info.durationMs}ms — $info',
      );
      _deleteQuietly(file.path);
      _deleteQuietly(path);
      await pumpFor(const Duration(milliseconds: 300));
    }

    // (a) Start-latency growth: median of the first three cycles vs the last.
    // The 400ms floor keeps scheduler jitter on a near-instant warm start from
    // tripping the ratio; a real per-cycle leak is hundreds of ms per cycle.
    final warm = startMs.take(3).toList()..sort();
    final median = warm[warm.length ~/ 2];
    final budgetMs = math.max((median * 2.5).round(), 400);
    expect(
      startMs.last,
      lessThan(budgetMs),
      reason:
          'startRecording latency grew from a ${median}ms warm median '
          '(cycles 1-3) to ${startMs.last}ms on cycle $cycles — per-cycle '
          'recorder state is accumulating. Per-cycle latencies: $startMs',
    );

    // (b) Preview health after the cycles vs before them.
    final after = await _collectFrames(const Duration(seconds: 3));
    expect(
      after.allFramesValid,
      isTrue,
      reason: 'preview went black/blown after $cycles record cycles ($after)',
    );
    expect(
      after.fps,
      greaterThan(before.fps * 0.7),
      reason:
          'preview FPS degraded across $cycles record cycles — '
          'before=${before.fps} after=${after.fps} (buffer/encoder leak). '
          'Per-cycle start latencies: $startMs',
    );

    // (c) The session is still error-free and can still record.
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason:
          '$cycles record cycles surfaced a session error '
          '("${cameraStore.errorMessage.value}"). Start latencies: $startMs',
    );
    expect(
      cameraStore.status.value,
      CameraStatus.running,
      reason: 'session is ${cameraStore.status.value} after $cycles cycles',
    );
    final fresh = await _recordProbeAndDelete(
      const Duration(seconds: 2),
      tag: 'cycle_fresh',
    );
    expect(
      fresh.isPlayable,
      isTrue,
      reason:
          'the session cannot record any more after $cycles cycles — the '
          'fresh clip is unplayable ($fresh). Start latencies: $startMs',
    );
  }

  // ── 2. Recorder state machine ───────────────────────────────────────────────

  /// The illegal-transition matrix against a LIVE session. Every call must be
  /// a no-op or a typed [CameraException]; none may hang, crash, leave
  /// `isRecording` wrong, or leave an orphan file. Afterwards the session must
  /// still preview AND still record — proving the state machine is not wedged.
  Future<void> recorderStateMachineRejectsIllegalCalls() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;

    // (a) stop with nothing started.
    await _illegal(
      'stopRecording() with nothing started',
      () async => c.stopRecording(),
    );
    expect(
      c.isRecording,
      isFalse,
      reason: 'a stray stopRecording() left the controller "recording"',
    );

    // (b) pause / resume with nothing started.
    await _illegal('pauseRecording() with nothing started', () async {
      c.pauseRecording();
      return null;
    });
    await _illegal('resumeRecording() with nothing started', () async {
      c.resumeRecording();
      return null;
    });
    expect(
      c.isRecording,
      isFalse,
      reason: 'pause/resume with no recording started one',
    );
    expect(
      c.isRecordingPaused,
      isFalse,
      reason: 'pause/resume with no recording flipped the paused flag',
    );

    // (e) cancel with nothing started.
    await _illegal('cancelRecording() with nothing started', () async {
      c.cancelRecording();
      return null;
    });
    expect(
      c.isRecording,
      isFalse,
      reason: 'a stray cancelRecording() left the controller "recording"',
    );

    // (c) start → stop → stop again immediately.
    final doubleStopPath = '${dir.path}/combo_sm_dstop_$stamp.mp4';
    await _awaitWithin(
      c.startRecording(doubleStopPath),
      deadline: const Duration(seconds: 15),
      label: 'startRecording for the double-stop case',
    );
    expect(c.isRecording, isTrue, reason: 'double-stop case never started');
    await pumpFor(const Duration(milliseconds: 1200));

    final first = await _resultWithin(
      c.stopRecording(),
      deadline: const Duration(seconds: 15),
      label: 'the legal stopRecording of the double-stop case',
    );
    final firstFile = File(first.path.isEmpty ? doubleStopPath : first.path);
    expect(
      firstFile.existsSync(),
      isTrue,
      reason: 'the legal stop reported "${first.path}" but wrote no file',
    );
    final firstInfo = probeMp4(firstFile);
    expect(
      firstInfo.isPlayable,
      isTrue,
      reason: 'the legal stop wrote an unplayable clip — $firstInfo',
    );
    _deleteQuietly(firstFile.path);
    _deleteQuietly(doubleStopPath);

    await _illegal(
      'a second stopRecording() immediately after a completed stop',
      () async => c.stopRecording(),
    );
    expect(
      c.isRecording,
      isFalse,
      reason: 'a double stopRecording() flipped the controller back to '
          '"recording"',
    );

    // (d) start → start again while already recording.
    final busyA = '${dir.path}/combo_sm_busyA_$stamp.mp4';
    final busyB = '${dir.path}/combo_sm_busyB_$stamp.mp4';
    await _awaitWithin(
      c.startRecording(busyA),
      deadline: const Duration(seconds: 15),
      label: 'startRecording for the double-start case',
    );
    expect(c.isRecording, isTrue, reason: 'double-start case never started');

    await _illegal('a second startRecording() while already recording', () async {
      await c.startRecording(busyB);
      return null;
    });
    expect(
      c.isRecording,
      isTrue,
      reason: 'the rejected second start killed the recording in flight',
    );
    expect(
      File(busyB).existsSync(),
      isFalse,
      reason:
          'the rejected second startRecording() left an ORPHAN file at '
          '$busyB — a start that never took effect must not create a file',
    );

    await pumpFor(const Duration(milliseconds: 1200));
    final busyRec = await _resultWithin(
      c.stopRecording(),
      deadline: const Duration(seconds: 15),
      label: 'stopRecording after a rejected second start',
    );
    expect(
      busyRec.path.isEmpty || busyRec.path == busyA,
      isTrue,
      reason:
          'stop finalised "${busyRec.path}" — the rejected second start '
          'hijacked the recording (the live clip was $busyA)',
    );
    final busyFile = File(busyRec.path.isEmpty ? busyA : busyRec.path);
    expect(
      busyFile.existsSync(),
      isTrue,
      reason: 'the double-start recording produced no file',
    );
    final busyInfo = probeMp4(busyFile);
    expect(
      busyInfo.isPlayable,
      isTrue,
      reason:
          'the clip surviving a rejected second start is unplayable — '
          '$busyInfo',
    );
    _deleteQuietly(busyFile.path);
    _deleteQuietly(busyA);
    _deleteQuietly(busyB);
    expect(
      c.isRecording,
      isFalse,
      reason: 'still "recording" after the double-start case was stopped',
    );

    // The matrix must have left the session completely usable.
    expect(
      cameraStore.status.value,
      CameraStatus.running,
      reason:
          'the illegal-transition matrix killed the session '
          '(status=${cameraStore.status.value})',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason:
          'illegal recorder transitions must be recorder-scoped, not session '
          'errors (got "${cameraStore.errorMessage.value}")',
    );
    final frames = await _collectFrames(const Duration(seconds: 2));
    expect(
      frames.frameCount,
      greaterThan(5),
      reason:
          'preview stopped delivering frames after the illegal-transition '
          'matrix ($frames)',
    );
    final fresh = await _recordProbeAndDelete(
      const Duration(seconds: 2),
      tag: 'sm_fresh',
    );
    expect(
      fresh.isPlayable,
      isTrue,
      reason:
          'the recorder state machine is WEDGED — a normal 2s recording after '
          'the illegal-transition matrix is unplayable ($fresh)',
    );
  }

  // ── 3. Reconfigure during recording ─────────────────────────────────────────

  /// Changes the session resolution (a close+reopen) WHILE a recording is in
  /// flight. Exactly two outcomes are acceptable and neither may crash:
  ///  A. the session reopens and the in-flight clip was FINALISED (playable);
  ///  B. the reconfigure is rejected while recording and the clip finalises
  ///     normally afterwards.
  ///
  /// A file that exists but has no `moov` is outcome (A) done wrong: the
  /// camera + capture session were closed without stopping the recorder.
  /// The texture-id sampling targets the unlocked check-then-
  /// `createCaptureSession` race (CameraSession.kt:449): a double reopen shows
  /// up as two distinct new texture ids.
  Future<void> configureDuringRecording() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/combo_cfg_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final beforeTid = cameraStore.activeTextureId.value;
    final tids = <int?>[];

    await _awaitWithin(
      c.startRecording(path),
      deadline: const Duration(seconds: 15),
      label: 'startRecording before the mid-recording reconfigure',
    );
    expect(
      c.isRecording,
      isTrue,
      reason: 'startRecording returned but isRecording is false',
    );
    await pumpFor(const Duration(seconds: 2));

    // Force a close+reopen underneath the live recorder.
    final wide = cameraStore.width.value >= 1920;
    cameraStore.setResolution(wide ? 1280 : 1920, wide ? 720 : 1080);

    final reopened = await _settles(
      () =>
          cameraStore.status.value == CameraStatus.running &&
          cameraStore.activeTextureId.value != null &&
          cameraStore.activeTextureId.value != beforeTid &&
          (cameraStore.activeController.value?.isInitialized ?? false),
      timeout: const Duration(seconds: 25),
      onPoll: () => tids.add(cameraStore.activeTextureId.value),
    );
    // Keep sampling AFTER the settle so a second reopen (the race) is seen too.
    for (var i = 0; i < 20; i++) {
      await pumpFor(const Duration(milliseconds: 100));
      tids.add(cameraStore.activeTextureId.value);
    }

    if (reopened) {
      // Outcome A — the reopen went through; the clip must have been finalised.
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'the session reopened (tid $beforeTid → '
            '${cameraStore.activeTextureId.value}) and the in-flight '
            'recording VANISHED — it was neither finalised nor rejected',
      );
      final info = probeMp4(file);
      expect(
        info.isPlayable,
        isTrue,
        reason:
            'the mid-recording reconfigure tore the camera down WITHOUT '
            'stopping the in-flight MediaRecorder — the clip has no moov and '
            'no player can open it ($info)',
      );
      _deleteQuietly(path);
    } else {
      // Outcome B — the reconfigure was rejected; nothing may have been lost.
      final live = cameraStore.activeController.value;
      expect(
        live,
        isNotNull,
        reason:
            'the mid-recording reconfigure left the session torn down '
            '(status=${cameraStore.status.value}, no active controller) — '
            'neither finalised nor rejected, the camera is WEDGED',
      );
      expect(
        identical(live, c),
        isTrue,
        reason:
            'the controller was replaced but the session never came back '
            'running (status=${cameraStore.status.value})',
      );
      expect(
        c.isRecording,
        isTrue,
        reason: 'the reconfigure was rejected but the recording died anyway',
      );
      final rec = await _resultWithin(
        c.stopRecording(),
        deadline: const Duration(seconds: 15),
        label: 'stopRecording after a rejected mid-recording reconfigure',
      );
      final file = File(rec.path.isEmpty ? path : rec.path);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'the rejected reconfigure still lost the clip ("${rec.path}")',
      );
      final info = probeMp4(file);
      expect(
        info.isPlayable,
        isTrue,
        reason:
            'the clip is unplayable after a REJECTED mid-recording '
            'reconfigure — $info',
      );
      _deleteQuietly(file.path);
      _deleteQuietly(path);
    }

    final reopens = tids.where((t) => t != null && t != beforeTid).toSet();
    expect(
      reopens.length,
      lessThanOrEqualTo(1),
      reason:
          'one resolution change reopened the session ${reopens.length} times '
          '(texture ids $reopens after $beforeTid) — the unlocked '
          'check-then-createCaptureSession path raced',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason:
          'a mid-recording reconfigure surfaced a session error '
          '("${cameraStore.errorMessage.value}")',
    );
    expect(
      cameraStore.status.value,
      CameraStatus.running,
      reason:
          'the session did not come back after a mid-recording reconfigure '
          '(status=${cameraStore.status.value})',
    );

    final fresh = await _recordProbeAndDelete(
      const Duration(seconds: 2),
      tag: 'cfg_fresh',
    );
    expect(
      fresh.isPlayable,
      isTrue,
      reason:
          'the post-reconfigure session cannot record — the fresh 2s clip is '
          'unplayable ($fresh)',
    );
  }

  // ── 4. Auto-stop limits and the state they leave behind ─────────────────────

  /// One auto-stop pass. Starts a recording carrying [options], waits for the
  /// native limit to fire, and validates everything it leaves behind.
  ///
  /// A stale `isRecording` is recorded into [lingering] instead of failing on
  /// the spot so BOTH limit passes and the recovery recording still run; the
  /// caller asserts the list is empty at the end.
  Future<({Mp4Info info, int fileSize})> _autoStopPass({
    required String tag,
    required RecordingOptions options,
    required RecordingFinishedReason expected,
    required Duration wait,
    required List<String> lingering,
  }) async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/combo_${tag}_'
        '${DateTime.now().millisecondsSinceEpoch}.mp4';

    // The native auto-stop finalises the file itself and announces it as a
    // `stopped` event carrying the path — there is no pending stopRecording
    // call to return it (CameraSession.startVideoRecording.onMaxReached).
    final stopped = <String>[];
    final sub = CameraController.allEvents
        .where((e) => e.type == CameraEventType.stopped && e.message.isNotEmpty)
        .listen((e) => stopped.add(e.message));

    await _awaitWithin(
      c.startRecording(path, options: options),
      deadline: const Duration(seconds: 15),
      label: '$tag startRecording',
    );
    expect(
      c.isRecording,
      isTrue,
      reason: '$tag: startRecording returned but isRecording is false',
    );

    final fired = await _settles(() => stopped.isNotEmpty, timeout: wait);
    await sub.cancel();
    expect(
      fired,
      isTrue,
      reason:
          '$tag: no auto-stop within ${wait.inSeconds}s — the '
          '${expected.name} limit never fired (maxDurationMs='
          '${options.maxDurationMs}, maxFileSizeBytes='
          '${options.maxFileSizeBytes})',
    );

    // Dart must see the recording finish WITHOUT an explicit stop call.
    final cleared = await _settles(
      () => !c.isRecording,
      timeout: const Duration(seconds: 3),
    );
    if (!cleared) {
      lingering.add(
        '$tag: controller.isRecording stayed TRUE for 3s after the native '
        '${expected.name} auto-stop — nothing clears '
        'CameraController._isRecording outside stopRecording()/'
        'cancelRecording(), so the app keeps showing a live recording',
      );
    }

    final file = File(stopped.first);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          '$tag: the auto-stop event carried "${stopped.first}" but no file '
          'is there',
    );
    final fileSize = file.lengthSync();
    final info = probeMp4(file);
    expect(
      info.isPlayable,
      isTrue,
      reason:
          '$tag: the auto-stopped clip is UNPLAYABLE — $info. The limit '
          'callback finalises MediaRecorder by re-entering it from its own '
          'callback thread (CameraSession.startVideoRecording.onMaxReached)',
    );

    // A subsequent EXPLICIT stop must be a clean no-op — not a hang, not a
    // crash, and never a second finalise of an already-released recorder.
    final explicitStop = await _resultWithin(
      c.stopRecording(),
      deadline: const Duration(seconds: 15),
      label: '$tag explicit stopRecording() after the auto-stop',
    );
    expect(
      c.isRecording,
      isFalse,
      reason: '$tag: still "recording" after an explicit stopRecording()',
    );
    if (explicitStop.isFinalized) {
      // Only reachable when the explicit stop beat the native auto-stop to the
      // recorder; then the reported reason MUST name the limit that fired.
      expect(
        explicitStop.reason,
        expected,
        reason:
            '$tag: the recorder reported ${explicitStop.reason.name} for a '
            '${expected.name} auto-stop',
      );
      _deleteQuietly(explicitStop.path);
    }
    _deleteQuietly(file.path);
    _deleteQuietly(path);
    return (info: info, fileSize: fileSize);
  }

  /// Drives BOTH native auto-stop limits (`maxDurationMs`, then
  /// `maxFileSizeBytes`) and audits the state each one leaves behind: a
  /// playable container sized/timed by the limit that actually fired, Dart
  /// recording state cleared without an explicit stop, a late explicit stop
  /// that neither hangs nor crashes, and a session that still records.
  ///
  /// Complements `CameraApis.verifyAutoStopRecording`, which only proves the
  /// stopped event carries a non-empty file for a maxDuration recording.
  Future<void> recordingAutoStopLimits() async {
    final lingering = <String>[];

    // ── Pass 1: maxDurationMs ──
    const durationLimitMs = 2500;
    final byDuration = await _autoStopPass(
      tag: 'autostop_dur',
      options: const RecordingOptions(
        bitRate: 4000000,
        maxDurationMs: durationLimitMs,
      ),
      expected: RecordingFinishedReason.maxDurationReached,
      wait: const Duration(seconds: 25),
      lingering: lingering,
    );
    expect(
      byDuration.info.durationMs,
      isNotNull,
      reason: 'the maxDuration clip carries no mvhd duration — '
          '${byDuration.info}',
    );
    expect(
      byDuration.info.durationMs!,
      greaterThan(durationLimitMs ~/ 2),
      reason:
          'maxDurationMs=$durationLimitMs but the clip is only '
          '${byDuration.info.durationMs}ms — the limit fired far too early',
    );
    expect(
      byDuration.info.durationMs!,
      lessThan(durationLimitMs + 4000),
      reason:
          'maxDurationMs=$durationLimitMs but the clip ran to '
          '${byDuration.info.durationMs}ms — the duration limit is not being '
          'honoured',
    );

    expect(
      cameraStore.status.value,
      CameraStatus.running,
      reason:
          'the maxDuration auto-stop left the session '
          '${cameraStore.status.value}',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason:
          'the maxDuration auto-stop surfaced a session error '
          '("${cameraStore.errorMessage.value}")',
    );

    // ── Pass 2: maxFileSizeBytes ──
    const sizeLimitBytes = 2000000;
    final bySize = await _autoStopPass(
      tag: 'autostop_size',
      options: const RecordingOptions(
        bitRate: 6000000,
        maxFileSizeBytes: sizeLimitBytes,
      ),
      expected: RecordingFinishedReason.maxFileSizeReached,
      wait: const Duration(seconds: 40),
      lingering: lingering,
    );
    expect(
      bySize.fileSize,
      lessThan(sizeLimitBytes * 2),
      reason:
          'maxFileSizeBytes=$sizeLimitBytes but the recorder wrote '
          '${bySize.fileSize} bytes — the size cap is not being honoured',
    );
    expect(
      bySize.fileSize,
      greaterThan(sizeLimitBytes ~/ 4),
      reason:
          'the auto-stop fired at ${bySize.fileSize} bytes, far below the '
          '$sizeLimitBytes cap — a different limit fired',
    );

    // Recovery: a plain recording still works after both limit auto-stops.
    final fresh = await _recordProbeAndDelete(
      const Duration(seconds: 2),
      tag: 'autostop_fresh',
    );
    expect(
      fresh.isPlayable,
      isTrue,
      reason:
          'the recorder is wedged after the limit auto-stops — a plain 2s '
          'recording is unplayable ($fresh)',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason:
          'the auto-stop passes surfaced a session error '
          '("${cameraStore.errorMessage.value}")',
    );
    expect(
      lingering,
      isEmpty,
      reason:
          'a native auto-stop left Dart recording state stale:\n'
          '${lingering.join('\n')}',
    );
  }
}
