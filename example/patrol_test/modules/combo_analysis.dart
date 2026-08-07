import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart'
    show
        expect,
        greaterThan,
        greaterThanOrEqualTo,
        isNotNull,
        isNull,
        isTrue,
        lessThan;
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import '../support/frame_stats.dart';
import '../support/mp4_probe.dart';
import 'camera_apis.dart' show createMeanLumaPlugin;
import 'module.dart';

/// COMBINATION module: **live analysis** features exercised TOGETHER with
/// recording and with each other.
///
/// Every existing test drives one feature at a time, so the pipeline
/// interactions stay untested — and that is exactly where the known Android
/// defects live:
///
///  * `startPreview()` (`session/CameraSession.kt:449`) is an unlocked
///    check-then-`createCaptureSession`, reachable from the Flutter thread
///    (mode / pixel-format switch), the recorder thread and the detector
///    thread at once → a reconfigure race that stalls or drops the frame
///    stream while a recording is in flight.
///  * `CameraSession.onAppStop` (`session/CameraSession.kt:336`) closes the
///    camera + session without stopping an in-flight recording, so the file
///    never gets its `moov` atom written — [Mp4Info.hasMoov] is the only
///    check that can see it.
///  * `MediaRecorder.setOrientationHint` is never called anywhere in the
///    Android source, so clips are stored in sensor orientation.
///  * Dart has no `AppLifecycleState` handling in `lib/`, and
///    `CameraFrameProcessor` never closes its `ReceivePort`
///    (`lib/src/processing/frame_processor.dart:153`) — a worker isolate that
///    dies while the app is backgrounded wedges the plugin runner forever,
///    including its `dispose()`.
final class ComboAnalysis extends Module {
  ComboAnalysis(super.$);

  CameraController get _ctrl => cameraStore.activeController.value!;

  // ── shared helpers ─────────────────────────────────────────────────────────

  String _clipPath(Directory dir, String tag) =>
      '${dir.path}/combo_${tag}_${DateTime.now().microsecondsSinceEpoch}.mp4';

  /// Structural (not self-reported) validation of a recorded clip.
  ///
  /// The plugin's own [RecordingResult] is written by the same code that may
  /// have failed, so it passes even for a truncated file. Reading the MP4's
  /// own boxes is what catches `onAppStop` tearing the session down without
  /// finalising the recorder.
  void _expectPlayableClip(
    File file, {
    required int minDurationMs,
    required String stage,
  }) {
    expect(
      file.existsSync(),
      isTrue,
      reason: 'no file on disk after stopRecording ($stage)',
    );
    final info = probeMp4(file);
    expect(
      info.hasMoov,
      isTrue,
      reason:
          'recorded clip has no moov atom ($stage) — the recorder was torn '
          'down without finalising (CameraSession.onAppStop closes the '
          'camera+session with a recording in flight, CameraSession.kt:336). '
          'File is ${file.lengthSync()} bytes but no player can open it. '
          '$info',
    );
    expect(
      info.isPlayable,
      isTrue,
      reason: 'recorded clip is structurally unplayable ($stage): $info',
    );
    expect(
      info.durationMs,
      isNotNull,
      reason: 'mvhd carries no duration ($stage): $info',
    );
    expect(
      info.durationMs!,
      greaterThanOrEqualTo(minDurationMs),
      reason:
          'clip is shorter than the recording window ($stage) — the encoder '
          'stopped receiving frames mid-clip while the analysis pipeline was '
          'live: $info',
    );
  }

  /// Waits until [counter] has advanced past [baseline] by [by] frames.
  Future<void> _expectFramesAdvance(
    int Function() counter,
    int baseline, {
    required String reason,
    int by = 5,
    Duration timeout = const Duration(seconds: 6),
  }) {
    return pumpUntil(
      () => counter() > baseline + by,
      timeout: timeout,
      reason: reason,
    );
  }

  void _expectSessionHealthy(CameraController c, String stage) {
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason: 'native error surfaced $stage: ${cameraStore.errorMessage.value}',
    );
    expect(
      cameraStore.status.value == CameraStatus.running,
      isTrue,
      reason: 'store status is ${cameraStore.status.value.name} $stage',
    );
    expect(
      c.getSessionState().running,
      isTrue,
      reason:
          'capture session is no longer streaming $stage — the unlocked '
          'startPreview() reconfigure path (CameraSession.kt:449) lost the '
          'session',
    );
  }

  // ── 1. recording + frame-processor plugin ─────────────────────────────────

  /// A 5 s recording while a frame-processor plugin runs on a worker isolate
  /// off the SAME frame stream.
  ///
  /// The video encoder attaching (and detaching) reconfigures the capture
  /// session while the CPU frame path is live — the three-thread
  /// `startPreview()` race (`CameraSession.kt:449`). A regression shows up as
  /// plugin results drying up for the duration of the clip, a multi-hundred
  /// millisecond frame gap, or frames never resuming after `stopRecording`.
  Future<void> recordingWithFrameProcessorPlugin() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final path = _clipPath(dir, 'plugin_rec');

    FrameProcessorPlugins.register('meanLuma', createMeanLumaPlugin);
    final runner = FrameProcessorPlugins.init('meanLuma', {'step': 64});
    final results = <Object?>[];
    final resultSub = runner.results.listen(results.add);
    var framesSeen = 0;
    final frameSub = c.frameStream.listen((_) => framesSeen++);
    final collector = FrameStatsCollector();
    var recordedPath = path;

    try {
      await runner.start(c.frameStream);
      c.setFrameProcessing(enabled: true);
      await pumpUntil(
        () => results.isNotEmpty,
        reason: 'plugin producing results from live frames before recording',
      );

      // Window starts here: it must span the whole record + post-record span.
      collector.attach(c.frameStream);
      final resultsBeforeRecord = results.length;

      await c.startRecording(
        path,
        options: const RecordingOptions(
          codec: 0, // h264
          fileType: 0, // mp4
          bitRate: 4_000_000,
        ),
      );
      expect(
        c.isRecording,
        isTrue,
        reason:
            'startRecording did not flip isRecording while a frame-processor '
            'plugin was consuming the stream',
      );
      await pumpFor(const Duration(seconds: 5));

      final rec = await c.stopRecording();
      recordedPath = rec.path;
      final resultsAfterRecord = results.length;
      final framesAtStop = framesSeen;

      expect(
        resultsAfterRecord,
        greaterThan(resultsBeforeRecord),
        reason:
            'the frame-processor plugin produced NO results during the 5 s '
            'recording ($resultsBeforeRecord → $resultsAfterRecord) — '
            'attaching the video encoder starved or killed the CPU frame '
            'path (the unlocked startPreview() reconfigure, '
            'CameraSession.kt:449)',
      );

      // Analysis must survive the recording teardown too.
      await pumpFor(const Duration(seconds: 3));
      final report = await collector.stop();

      expect(
        framesSeen,
        greaterThan(framesAtStop + 5),
        reason:
            'frames stopped flowing after stopRecording '
            '($framesAtStop → $framesSeen) — the recorder teardown took the '
            'preview/CPU stream down with it',
      );
      expect(
        report.maxGapMs,
        lessThan(800),
        reason:
            'frame stream stalled for ${report.maxGapMs}ms across the '
            'record/stop window — the encoder attach/detach reconfigure '
            'blocks frame delivery ($report)',
      );
      expect(
        report.allFramesValid,
        isTrue,
        reason:
            'a degenerate (black/blown) frame was delivered while recording '
            'with the plugin attached ($report)',
      );

      _expectPlayableClip(
        File(recordedPath),
        minDurationMs: 4500,
        stage: 'recording alongside a frame-processor plugin',
      );
      _expectSessionHealthy(c, 'after recording with a plugin attached');
    } finally {
      c.setFrameProcessing(enabled: false);
      await collector.stop();
      await frameSub.cancel();
      await resultSub.cancel();
      await runner.dispose();
      for (final p in {path, recordedPath}) {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      }
    }
  }

  // ── 2. recording + code scanner ───────────────────────────────────────────

  /// Recording from inside SCANNER mode — the "scan a code, capture proof"
  /// UX.
  ///
  /// SCANNER flips the frame format to YUV (`CameraStore.setMode` →
  /// `setPixelFormat(0)`), i.e. a live session reconfigure, and then the
  /// recorder attaches on top of it. Two reconfigure paths racing on the
  /// unlocked `startPreview()` (`CameraSession.kt:449`) show up here as a
  /// stalled scanner, an unplayable clip, or a session that never comes back
  /// when the mode is restored.
  Future<void> recordingWhileScanning() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final path = _clipPath(dir, 'scanner_rec');

    var framesSeen = 0;
    final frameSub = c.frameStream.listen((_) => framesSeen++);
    final collector = FrameStatsCollector();
    var recordedPath = path;

    try {
      await cameraStore.setMode('SCANNER');
      await _expectFramesAdvance(
        () => framesSeen,
        0,
        by: 4,
        timeout: const Duration(seconds: 10),
        reason:
            'no frames after entering SCANNER mode — the YUV pixel-format '
            'reconfigure killed frame delivery',
      );

      // Window starts once the scanner is warm: it spans record + stop + the
      // post-recording scanning span.
      collector.attach(c.frameStream);
      final framesAtRecordStart = framesSeen;

      await c.startRecording(
        path,
        options: const RecordingOptions(
          codec: 0, // h264
          fileType: 0, // mp4
          bitRate: 4_000_000,
        ),
      );
      expect(
        c.isRecording,
        isTrue,
        reason: 'startRecording did not engage while in SCANNER mode',
      );
      await pumpFor(const Duration(seconds: 5));
      expect(
        framesSeen,
        greaterThan(framesAtRecordStart + 20),
        reason:
            'the scanner stopped receiving frames during the recording '
            '($framesAtRecordStart → $framesSeen in 5 s) — the recorder '
            'reconfigure evicted the CPU frame consumer',
      );

      final rec = await c.stopRecording();
      recordedPath = rec.path;
      final framesAtStop = framesSeen;

      // Scanning must survive the recorder teardown.
      await pumpFor(const Duration(seconds: 3));
      final report = await collector.stop();

      expect(
        framesSeen,
        greaterThan(framesAtStop + 5),
        reason:
            'the scanner is dead after stopRecording '
            '($framesAtStop → $framesSeen) — recorder teardown took the '
            'frame stream with it',
      );
      expect(
        report.maxGapMs,
        lessThan(800),
        reason:
            'scanner frame delivery stalled for ${report.maxGapMs}ms across '
            'the record/stop sequence — a code passing the lens in that '
            'window is missed ($report)',
      );

      _expectPlayableClip(
        File(recordedPath),
        minDurationMs: 4500,
        stage: 'recording while in SCANNER mode',
      );
      _expectSessionHealthy(c, 'after recording from SCANNER mode');

      // Back to PHOTO: a second pixel-format reconfigure right after the
      // recorder teardown.
      await cameraStore.setMode('PHOTO');
      await pumpUntil(
        () =>
            cameraStore.status.value == CameraStatus.running &&
            (cameraStore.activeController.value?.isInitialized ?? false),
        timeout: const Duration(seconds: 15),
        reason:
            'session never recovered after leaving SCANNER mode following a '
            'recording (BGRA reconfigure on a session the recorder just '
            'let go)',
      );
      _expectSessionHealthy(
        cameraStore.activeController.value!,
        'after restoring PHOTO mode',
      );
    } finally {
      await collector.stop();
      await frameSub.cancel();
      if (cameraStore.mode.value != 'PHOTO') {
        await cameraStore.setMode('PHOTO');
      }
      for (final p in {path, recordedPath}) {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      }
    }
  }

  // ── 3. recording + native ML detector churn ───────────────────────────────

  /// Recording while the native ML Kit detector is swapped mid-clip
  /// (barcode → face → off → barcode).
  ///
  /// Each `startDetector` / `stopDetector` builds and releases a per-texture
  /// detector engine on the analysis path while the encoder holds a second
  /// surface on the same session. The frame stream must survive every swap,
  /// the clip must still finalise, and the session must be able to record
  /// again afterwards.
  ///
  /// ML Kit is an OPTIONAL native dependency: when it is absent no
  /// [DetectionResult] ever arrives, which is NOT a failure — the frame-flow
  /// and recording invariants are what this test defends.
  Future<void> recordingWithNativeDetector() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final path = _clipPath(dir, 'detector_rec');
    final freshPath = _clipPath(dir, 'detector_fresh');

    final detections = <DetectionResult>[];
    final detSub = c.detections.listen(detections.add);
    final errorEvents = <String>[];
    final eventSub = c.events
        .where((e) => e.isError)
        .listen((e) => errorEvents.add(e.message));
    var framesSeen = 0;
    final frameSub = c.frameStream.listen((_) => framesSeen++);
    var recordedPath = path;
    var freshRecordedPath = freshPath;

    try {
      c.setFrameProcessing(enabled: true);
      c.startDetector(NativeDetector.barcode);
      await _expectFramesAdvance(
        () => framesSeen,
        0,
        reason: 'frame stream never started with the barcode detector attached',
      );

      final clock = Stopwatch()..start();
      await c.startRecording(
        path,
        options: const RecordingOptions(
          codec: 0, // h264
          fileType: 0, // mp4
          bitRate: 4_000_000,
        ),
      );
      expect(
        c.isRecording,
        isTrue,
        reason: 'startRecording did not engage with a detector running',
      );
      await pumpFor(const Duration(milliseconds: 1200));

      // Mid-clip detector churn: every swap tears down and rebuilds an
      // analysis engine underneath a live encoder.
      const churn = <NativeDetector?>[
        NativeDetector.face,
        null, // stopDetector
        NativeDetector.barcode,
      ];
      for (final d in churn) {
        final before = framesSeen;
        if (d == null) {
          c.stopDetector();
        } else {
          c.startDetector(d);
        }
        await _expectFramesAdvance(
          () => framesSeen,
          before,
          timeout: const Duration(seconds: 5),
          reason:
              'frames stopped after swapping the native detector to '
              '${d?.name ?? 'off'} mid-recording — the detector engine '
              'lifecycle wedged the analysis path while the encoder held the '
              'session',
        );
        expect(
          c.isRecording,
          isTrue,
          reason:
              'the recording died when the detector was swapped to '
              '${d?.name ?? 'off'} mid-clip',
        );
      }

      final remainingMs = 5000 - clock.elapsedMilliseconds;
      if (remainingMs > 0) {
        await pumpFor(Duration(milliseconds: remainingMs));
      }
      final rec = await c.stopRecording();
      recordedPath = rec.path;
      c.stopDetector();

      for (final d in detections) {
        expect(
          NativeDetector.values.contains(d.detector),
          isTrue,
          reason: 'detection carried an unknown detector kind: ${d.detector}',
        );
        expect(
          d.frameWidth,
          greaterThan(0),
          reason:
              'malformed DetectionResult (frameWidth=${d.frameWidth}) — the '
              'detector reported on a frame it never actually got',
        );
        expect(
          d.frameHeight,
          greaterThan(0),
          reason:
              'malformed DetectionResult (frameHeight=${d.frameHeight}) — the '
              'detector reported on a frame it never actually got',
        );
      }

      expect(
        errorEvents.isEmpty,
        isTrue,
        reason:
            'the session emitted error events during detector churn under '
            'recording: $errorEvents',
      );
      _expectPlayableClip(
        File(recordedPath),
        minDurationMs: 4500,
        stage: 'recording across barcode→face→off→barcode detector churn',
      );
      _expectSessionHealthy(c, 'after detector churn under recording');

      // The session must still be able to record: a leaked analysis engine or
      // a half-released encoder surface only shows on the NEXT start.
      await c.startRecording(freshPath);
      expect(
        c.isRecording,
        isTrue,
        reason:
            'a second recording will not start after detector churn — a '
            'detector engine or encoder surface was leaked by the first clip',
      );
      await pumpFor(const Duration(seconds: 2));
      final fresh = await c.stopRecording();
      freshRecordedPath = fresh.path;
      _expectPlayableClip(
        File(freshRecordedPath),
        minDurationMs: 1500,
        stage: 'fresh clip recorded after detector churn',
      );
      _expectSessionHealthy(c, 'after the follow-up recording');
    } finally {
      c.stopDetector();
      c.setFrameProcessing(enabled: false);
      await frameSub.cancel();
      await detSub.cancel();
      await eventSub.cancel();
      for (final p in {path, recordedPath, freshPath, freshRecordedPath}) {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      }
    }
  }

  // ── 4. frame-processor plugin across background/foreground ────────────────

  /// The plugin worker isolate must survive an app background/foreground
  /// cycle — and must still be disposable afterwards.
  ///
  /// Nothing in `lib/` handles `AppLifecycleState`, and
  /// `CameraFrameProcessor.start`
  /// (`lib/src/processing/frame_processor.dart:153`) creates a `ReceivePort`
  /// it never closes: if the worker dies while the app is stopped, the runner
  /// keeps a live port and no completer ever fires, so BOTH new results and
  /// `dispose()` hang forever. The 10 s results check and the 5 s dispose race
  /// are the two halves of that defect.
  Future<void> frameProcessorSurvivesBackgrounding() async {
    FrameProcessorPlugins.register('meanLuma', createMeanLumaPlugin);
    final runner = FrameProcessorPlugins.init('meanLuma', {'step': 64});
    final results = <Object?>[];
    final stats = <FrameProcessStats>[];
    final resultSub = runner.results.listen(results.add);
    final statsSub = runner.stats.listen(stats.add);
    // The runner binds to ONE stream for its whole life; the relay keeps that
    // stream stable so a session reopen on resume cannot be mistaken for a
    // wedged worker isolate.
    final relay = _FrameRelay()..bind(_ctrl);
    var disposeStarted = false;

    try {
      await runner.start(relay.stream);
      _ctrl.setFrameProcessing(enabled: true);
      await pumpUntil(
        () => results.length >= 3 && stats.isNotEmpty,
        reason: 'plugin producing results before backgrounding',
      );
      final resultsBefore = results.length;
      final statsBefore = stats.length;

      await $.platform.mobile.pressHome();
      // RAW delay while backgrounded — pump() deadlocks against a paused
      // engine.
      await Future<void>.delayed(const Duration(seconds: 3));
      await $.platform.mobile.openApp();
      await Future<void>.delayed(const Duration(seconds: 1));

      await pumpUntil(
        () =>
            cameraStore.status.value == CameraStatus.running &&
            (cameraStore.activeController.value?.isInitialized ?? false),
        timeout: const Duration(seconds: 25),
        reason: 'preview never came back after background → foreground',
      );

      final resumed = cameraStore.activeController.value!;
      relay.bind(resumed);
      resumed.setFrameProcessing(enabled: true);

      await pumpUntil(
        () => results.length > resultsBefore,
        timeout: const Duration(seconds: 10),
        reason:
            'no NEW frame-processor plugin results within 10 s of resuming '
            '(stuck at $resultsBefore) — the worker isolate did not survive '
            'the background cycle and CameraFrameProcessor never notices '
            '(its ReceivePort is never closed, '
            'lib/src/processing/frame_processor.dart:153)',
      );
      expect(
        stats.length,
        greaterThan(statsBefore),
        reason:
            'plugin timing stats stopped ticking after resume '
            '($statsBefore → ${stats.length}) — frames reach the runner but '
            'the worker no longer reports, i.e. a half-dead isolate',
      );

      // dispose() must COMPLETE, not hang on the orphaned port. Run it
      // detached and poll: awaiting it directly would hang the whole test
      // instead of failing it.
      disposeStarted = true;
      var disposed = false;
      Object? disposeError;
      unawaited(() async {
        try {
          await runner.dispose();
          disposed = true;
        } catch (e) {
          disposeError = e;
        }
      }());
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!disposed &&
          disposeError == null &&
          DateTime.now().isBefore(deadline)) {
        await pumpFor(const Duration(milliseconds: 250));
      }
      expect(
        disposeError,
        isNull,
        reason:
            'runner.dispose() threw after a background cycle: $disposeError',
      );
      expect(
        disposed,
        isTrue,
        reason:
            'runner.dispose() did not complete within 5 s after a '
            'background/foreground cycle — the un-closed ReceivePort '
            '(lib/src/processing/frame_processor.dart:153) keeps the isolate '
            'handle alive and wedges teardown, leaking the worker for the '
            'rest of the app session',
      );
    } finally {
      cameraStore.activeController.value?.setFrameProcessing(enabled: false);
      await resultSub.cancel();
      await statsSub.cancel();
      await relay.dispose();
      if (!disposeStarted) {
        // Never await a dispose that may hang — that is the defect under test.
        unawaited(() async {
          try {
            await runner.dispose();
          } catch (_) {
            // Teardown-path best effort; the assertion path owns the verdict.
          }
        }());
      }
    }
  }

  // ── 5. scanner + zoom sweep + torch ───────────────────────────────────────

  /// The real close-range scanning UX: SCANNER mode with the torch on while
  /// the user zooms in on a code and back out.
  ///
  /// Torch and zoom are live capture-request edits issued from the Flutter
  /// thread against a session whose analysis path is streaming YUV frames.
  /// A dropped/rebuilt capture request shows up as a frame gap or, worse, as
  /// a stuck preview: [FrameStreamReport.allFramesValid] is a PIXEL-level
  /// check, so a frozen or black surface fails even though frames keep
  /// arriving.
  Future<void> scannerWithZoomAndTorch() async {
    final c = _ctrl;
    final hasTorch = c.device.hasTorch;
    var framesSeen = 0;
    final frameSub = c.frameStream.listen((_) => framesSeen++);
    final collector = FrameStatsCollector();

    try {
      await cameraStore.setMode('SCANNER');
      await _expectFramesAdvance(
        () => framesSeen,
        0,
        by: 4,
        timeout: const Duration(seconds: 10),
        reason:
            'no frames after entering SCANNER mode — the YUV pixel-format '
            'reconfigure killed frame delivery',
      );

      collector.attach(c.frameStream);

      if (hasTorch) {
        c.setTorch(enabled: true);
        expect(
          c.torch,
          isTrue,
          reason: 'setTorch(true) did not take effect in SCANNER mode',
        );
        await pumpFor(const Duration(milliseconds: 400));
      } else {
        // ignore: avoid_print
        print(
          'scannerWithZoomAndTorch: no torch on this device — torch steps '
          'skipped, zoom sweep still asserted',
        );
      }

      // Zoom sweep min → max → min, 12 steps each way (25 setZoom calls).
      const steps = 12;
      final minZoom = c.device.minZoom;
      final span = c.device.maxZoom - minZoom;
      for (var i = 0; i <= steps; i++) {
        c.setZoom(minZoom + span * (i / steps));
        await pumpFor(const Duration(milliseconds: 180));
      }
      for (var i = steps - 1; i >= 0; i--) {
        c.setZoom(minZoom + span * (i / steps));
        await pumpFor(const Duration(milliseconds: 180));
      }
      expect(
        c.zoom,
        minZoom,
        reason:
            'zoom did not return to $minZoom after the sweep (got ${c.zoom}) — '
            'a live zoom edit was dropped while the scanner was streaming',
      );

      if (hasTorch) {
        c.setTorchLevel(0.5);
        await pumpFor(const Duration(milliseconds: 500));
        c.setTorch(enabled: false);
        await pumpFor(const Duration(milliseconds: 400));
      }

      final report = await collector.stop();
      expect(
        report.frameCount,
        greaterThan(20),
        reason:
            'far too few frames across the scan sweep (${report.frameCount}) — '
            'the scanner stalled under torch + zoom traffic ($report)',
      );
      expect(
        report.maxGapMs,
        lessThan(900),
        reason:
            'scanner frame delivery stalled for ${report.maxGapMs}ms during '
            'the torch + zoom sweep — a code in view during that window is '
            'never decoded ($report)',
      );
      expect(
        report.allFramesValid,
        isTrue,
        reason:
            'the preview went black or froze at the pixel level during the '
            'torch + zoom sweep ($report)',
      );
      _expectSessionHealthy(c, 'after the SCANNER torch + zoom sweep');

      // Leaving SCANNER reconfigures the format again — the session must
      // still deliver a live preview afterwards.
      await cameraStore.setMode('PHOTO');
      await pumpUntil(
        () =>
            cameraStore.status.value == CameraStatus.running &&
            (cameraStore.activeController.value?.isInitialized ?? false),
        timeout: const Duration(seconds: 15),
        reason: 'session never recovered after leaving SCANNER mode',
      );
      // Count on the CURRENT controller: if the mode round-trip reopened the
      // session, `frameSub` above is filtered to a dead textureId and would
      // report a false "preview is dead".
      final after = cameraStore.activeController.value!;
      var framesAfter = 0;
      final afterSub = after.frameStream.listen((_) => framesAfter++);
      after.setFrameProcessing(enabled: true);
      try {
        await _expectFramesAdvance(
          () => framesAfter,
          0,
          timeout: const Duration(seconds: 10),
          reason:
              'no frames in PHOTO mode after the SCANNER torch + zoom sweep — '
              'the preview is dead, not merely idle',
        );
      } finally {
        after.setFrameProcessing(enabled: false);
        await afterSub.cancel();
      }
      _expectSessionHealthy(after, 'after returning to PHOTO mode');
    } finally {
      // Restore on the LIVE controller — `c` may have been superseded if the
      // mode round-trip reopened the session, and a throwing teardown would
      // mask the real assertion failure.
      final live = cameraStore.activeController.value;
      if (live != null && live.isInitialized) {
        if (live.device.hasTorch) live.setTorch(enabled: false);
        live.setZoom(live.device.minZoom);
      }
      await collector.stop();
      await frameSub.cancel();
      if (cameraStore.mode.value != 'PHOTO') {
        await cameraStore.setMode('PHOTO');
      }
    }
  }
}

/// Republishes the ACTIVE session's frames on one stable stream.
///
/// A [FrameProcessorPluginRunner] binds to a single stream for its whole
/// life, but `CameraController.frameStream` is filtered by `textureId` — so a
/// session reopen (e.g. on resume) would silently starve the runner. The
/// relay re-binds to the current controller instead, keeping the runner's own
/// liveness the only thing under test.
///
/// Delivery is `sync: true` on purpose: a [CameraFrame]'s pixel buffer is a
/// zero-copy borrow that is recycled once the listener returns, so an async
/// hop would hand consumers a stale buffer.
final class _FrameRelay {
  final _out = StreamController<CameraFrame>.broadcast(sync: true);
  StreamSubscription<CameraFrame>? _in;
  int? _boundTextureId;

  Stream<CameraFrame> get stream => _out.stream;

  void bind(CameraController c) {
    if (_in != null && _boundTextureId == c.textureId) return;
    _in?.cancel();
    _boundTextureId = c.textureId;
    _in = c.frameStream.listen(_out.add);
  }

  Future<void> dispose() async {
    await _in?.cancel();
    _in = null;
    await _out.close();
  }
}
