import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show MaterialApp, SizedBox, Widget;
import 'package:flutter_test/flutter_test.dart'
    show
        TestFailure,
        expect,
        greaterThan,
        greaterThanOrEqualTo,
        isFalse,
        isNotEmpty,
        isNotNull,
        isNull,
        isTrue,
        lessThan;
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import '../support/frame_stats.dart';
import '../support/mp4_probe.dart';
import 'module.dart';

/// COMBINATION scenarios weighted to **video recording**: recording crossed
/// with the app lifecycle, orientation, still capture, lens switching, the
/// live-setter storm, the GPU filter pipeline and the audio track.
///
/// Every single-feature recording test in the suite consumes the plugin's own
/// [RecordingResult] — path / fileSize / durationMs / reason — so a clip the
/// recorder BELIEVES it wrote passes even when it is truncated, rotated or
/// silently muted. These methods assert against the container's own boxes
/// ([probeMp4]) and against the preview's frame cadence
/// ([FrameStatsCollector]) instead, which is where the production defects
/// actually show up.
final class ComboRecording extends Module {
  ComboRecording(super.$);

  /// The live session controller (valid after `camera.openAppToPreview()`).
  CameraController get _ctrl => cameraStore.activeController.value!;

  Future<String> _tempPath(String tag) async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/combo_${tag}_'
        '${DateTime.now().microsecondsSinceEpoch}.mp4';
  }

  void _deleteIfPresent(String? path) {
    if (path == null || path.isEmpty) return;
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }

  /// Awaits [op] while the engine KEEPS PUMPING, failing with [label] once
  /// [deadline] elapses.
  ///
  /// A hang — not a wrong value — is the headline failure mode of these
  /// combinations: a `stopRecording()` that never returns after the session
  /// was torn down underneath the recorder, or a `takePhoto()` wedged behind
  /// two leaked `Image`s on the `maxImages=2` reader
  /// (`android/.../outputs/PhotoOutput.kt:513-524`). Patrol's global timeout
  /// would report that as an opaque suite abort, so race the call against an
  /// explicit deadline that names the operation.
  Future<T> awaitWithDeadline<T>(
    Future<T> op, {
    required Duration deadline,
    required String label,
  }) async {
    final guard = Completer<T>();
    final timer = Timer(deadline, () {
      if (!guard.isCompleted) {
        guard.completeError(
          TestFailure(
            '$label did not complete within ${deadline.inMilliseconds}ms — '
            'the call is STUCK (store error: '
            '${cameraStore.errorMessage.value})',
          ),
        );
      }
    });
    var pumping = true;
    unawaited(() async {
      while (pumping) {
        await $.tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }());
    try {
      // Future.any ignores whichever future loses the race, so a late
      // completion of [op] after the deadline fired cannot surface as an
      // unhandled error.
      return await Future.any<T>([op, guard.future]);
    } finally {
      pumping = false;
      timer.cancel();
    }
  }

  /// Pumps until [condition] holds or [timeout] elapses, WITHOUT failing —
  /// for the branches where "it never happened" is itself a documented
  /// outcome (e.g. a lens switch the recorder legitimately refuses).
  Future<bool> _pumpWhile(
    bool Function() condition, {
    required Duration timeout,
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (condition()) return true;
      await pumpFor(const Duration(milliseconds: 250));
    }
    return condition();
  }

  /// Keeps the recording running until [total] has elapsed on [wall].
  Future<void> _padTo(Stopwatch wall, Duration total) async {
    final remaining = total - wall.elapsed;
    if (remaining > Duration.zero) await pumpFor(remaining);
  }

  // ── 1. recording × app lifecycle ───────────────────────────────────────────

  /// A recording that spans a background → foreground round trip must end
  /// HONESTLY: either a finalised, playable file, or a thrown
  /// [RecorderException]. Never a reported success over a truncated file, and
  /// never a hang.
  ///
  /// Defect hunted: `CameraSession.onAppStop`
  /// (`android/src/main/kotlin/dev/shreeman/nitro_camera/session/CameraSession.kt:336`)
  /// closes the camera device and the capture session without stopping an
  /// in-flight `MediaRecorder`, so the `moov` atom is never written. The file
  /// is non-empty and its reported size is plausible — `hasMoov == false` on
  /// the container is the only observation that catches it.
  Future<void> recordingSurvivesBackgrounding() async {
    final recorded = _ctrl;
    final path = await _tempPath('bg');

    await recorded.startRecording(path);
    expect(
      recorded.isRecording,
      isTrue,
      reason: 'startRecording() did not arm the recorder',
    );
    await pumpFor(const Duration(seconds: 2));

    await $.platform.mobile.pressHome();
    // RAW delay while backgrounded — pump() would deadlock: the engine is
    // paused and never produces the frame the pump awaits.
    await Future<void>.delayed(const Duration(seconds: 3));
    await $.platform.mobile.openApp();
    await Future<void>.delayed(const Duration(seconds: 1));

    await pumpUntil(
      () =>
          cameraStore.status.value == CameraStatus.running &&
          (cameraStore.activeController.value?.isInitialized ?? false),
      timeout: const Duration(seconds: 30),
      reason:
          'preview never came back after background → foreground while a '
          'recording was in flight — onAppStop (CameraSession.kt:336) left '
          'the session dead',
    );

    final live = cameraStore.activeController.value;
    expect(
      live,
      isNotNull,
      reason: 'no controller after foregrounding — the session was dropped',
    );

    final file = File(path);
    String? resultPath;

    if (identical(live, recorded) && recorded.isRecording) {
      RecordingResult? result;
      var threwRecorderException = false;
      try {
        result = await awaitWithDeadline(
          recorded.stopRecording(),
          deadline: const Duration(seconds: 20),
          label:
              'stopRecording() after a background → foreground round trip',
        );
      } on RecorderException catch (_) {
        // The honest outcome: the plugin admits the clip could not be
        // finalised and discards it.
        threwRecorderException = true;
      }

      if (!threwRecorderException) {
        resultPath = result!.path;
        final produced = File(resultPath);
        expect(
          produced.existsSync(),
          isTrue,
          reason:
              'stopRecording() reported success (${result.fileSize} bytes, '
              'reason=${result.reason}) but wrote no file at $resultPath',
        );
        final info = probeMp4(produced);
        expect(
          info.hasMoov,
          isTrue,
          reason:
              'SILENT TRUNCATION: stopRecording() returned success '
              '(${result.fileSize} bytes, reason=${result.reason}) over a '
              'container with no moov atom ($info) — CameraSession.onAppStop '
              '(CameraSession.kt:336) closed the camera + session on '
              'background without stopping the MediaRecorder, so nothing '
              'finalised the file. It must either finalise it or throw '
              'RecorderException.',
        );
        expect(
          info.isPlayable,
          isTrue,
          reason:
              'the clip that spanned backgrounding is not playable '
              '($info) even though stopRecording() reported success',
        );
      }
    } else {
      // The session was recreated across the round trip, so nothing could
      // ever stop that recorder. Whatever it left on disk must still be
      // honest — an unfinalised orphan is the same defect by another route.
      if (file.existsSync() && file.lengthSync() > 0) {
        final info = probeMp4(file);
        expect(
          info.isPlayable,
          isTrue,
          reason:
              'the session was recreated across backgrounding and abandoned '
              'an unplayable clip ($info) — CameraSession.onAppStop '
              '(CameraSession.kt:336) tears the session down without '
              'stopping the in-flight recorder',
        );
      }
    }

    expect(
      live!.isRecording,
      isFalse,
      reason:
          'the controller still claims isRecording after the recording '
          'ended — a stale flag blocks every later start (VideoOutput.kt:167 '
          'leaves isRecording=true behind a failed start)',
    );
    expect(
      live.getSessionState().running,
      isTrue,
      reason:
          'the preview session is not running after the recording ended — '
          'the lifecycle teardown took the camera with it',
    );

    _deleteIfPresent(path);
    if (resultPath != path) _deleteIfPresent(resultPath);
  }

  // ── 2. recording × target orientation ──────────────────────────────────────

  /// The requested target orientation must reach the CONTAINER, not just the
  /// preview: a clip recorded under `setTargetOrientation(90)` has to carry a
  /// 90° `tkhd` transform matrix.
  ///
  /// Defect hunted: `MediaRecorder.setOrientationHint` is never called
  /// anywhere in the Android source, so the persistent-input-surface path
  /// stores frames in SENSOR orientation and every player shows the clip
  /// rotated. The bytes are fine; only the `tkhd` matrix reveals it, which is
  /// why this reads [Mp4Info.rotationDegrees] rather than the plugin's own
  /// [RecordingResult]. EXPECTED TO FAIL on Android until the hint is wired.
  Future<void> recordedVideoCarriesRequestedOrientation() async {
    final c = _ctrl;
    const requested = [0, 90];
    final observed = <int, int?>{};

    for (final degrees in requested) {
      cameraStore.setTargetOrientation(degrees);
      await pumpFor(const Duration(milliseconds: 500));

      final path = await _tempPath('orient$degrees');
      await c.startRecording(path);
      await pumpFor(const Duration(seconds: 2));
      final rec = await awaitWithDeadline(
        c.stopRecording(),
        deadline: const Duration(seconds: 20),
        label: 'stopRecording() for targetOrientation=$degrees',
      );

      final info = probeMp4(File(rec.path));
      expect(
        info.isPlayable,
        isTrue,
        reason:
            'the targetOrientation=$degrees clip is not playable ($info) — '
            'orientation must not break finalisation',
      );
      observed[degrees] = info.rotationDegrees;

      _deleteIfPresent(rec.path);
      if (rec.path != path) _deleteIfPresent(path);
    }

    cameraStore.setTargetOrientation(-1); // restore AUTO
    await pumpFor(const Duration(milliseconds: 300));

    for (final degrees in requested) {
      expect(
        observed[degrees],
        degrees,
        reason:
            'recorded orientation does not match the request — '
            'requested→observed: $observed. MediaRecorder.setOrientationHint '
            'is never called, so the clip is muxed in sensor orientation '
            'and plays back rotated.',
      );
    }
  }

  // ── 3. recording × still capture ───────────────────────────────────────────

  /// Stills taken DURING a recording must all come back, must not break the
  /// clip, and must not poison the still pipeline for the next capture.
  ///
  /// Defect hunted: `PhotoOutput.takePhotoWithRequest`
  /// (`android/.../outputs/PhotoOutput.kt:513-524`) leaks the acquired
  /// `Image` on every exception path. The reader is `maxImages=2`, so two
  /// leaks wedge still capture PERMANENTLY — which is what the fifth photo,
  /// taken after the recording has stopped, is a tripwire for.
  Future<void> photoCaptureDuringRecording() async {
    final c = _ctrl;
    final videoPath = await _tempPath('rec_photo');
    final photos = <String>[];

    final wall = Stopwatch()..start();
    await c.startRecording(videoPath);
    expect(c.isRecording, isTrue, reason: 'startRecording() did not arm');

    for (var i = 1; i <= 4; i++) {
      await pumpFor(const Duration(milliseconds: 1500));
      final shot = await awaitWithDeadline(
        c.takePhoto(),
        deadline: const Duration(seconds: 15),
        label:
            'takePhoto() #$i DURING recording (a wedged still pipeline is '
            'the leaked-Image path, PhotoOutput.kt:513-524)',
      );
      photos.add(shot.path);
    }

    await _padTo(wall, const Duration(seconds: 8));
    final rec = await awaitWithDeadline(
      c.stopRecording(),
      deadline: const Duration(seconds: 20),
      label: 'stopRecording() after 4 concurrent stills',
    );
    wall.stop();

    for (var i = 0; i < photos.length; i++) {
      final f = File(photos[i]);
      expect(
        f.existsSync(),
        isTrue,
        reason:
            'photo ${i + 1} of 4 taken during the recording wrote no file '
            '(${photos[i]}) — the still path silently dropped a capture',
      );
      expect(
        f.lengthSync(),
        greaterThan(0),
        reason:
            'photo ${i + 1} of 4 taken during the recording is 0 bytes — '
            'the JPEG was never written',
      );
    }

    final info = probeMp4(File(rec.path));
    expect(
      info.isPlayable,
      isTrue,
      reason:
          'the clip is unplayable after 4 stills were interleaved into it '
          '($info) — still capture must not break recorder finalisation',
    );
    expect(
      info.durationMs,
      isNotNull,
      reason: 'no mvhd duration in the clip ($info) — container is malformed',
    );
    expect(
      info.durationMs!,
      greaterThanOrEqualTo(6500),
      reason:
          'the clip is only ${info.durationMs}ms of a >=8s recording window '
          '(plugin reported ${rec.durationMs}ms) — the recorder dropped '
          'frames or stalled while stills were being captured',
    );

    // Leak tripwire: two leaked Images on a maxImages=2 reader make this
    // capture never return.
    final after = await awaitWithDeadline(
      c.takePhoto(),
      deadline: const Duration(seconds: 15),
      label:
          'takePhoto() AFTER a recording with 4 interleaved stills — the '
          'ImageReader is maxImages=2, so two Images leaked by '
          'PhotoOutput.takePhotoWithRequest (PhotoOutput.kt:513-524) wedge '
          'still capture permanently',
    );
    final afterFile = File(after.path);
    expect(
      afterFile.existsSync() && afterFile.lengthSync() > 0,
      isTrue,
      reason:
          'the still taken after the recording produced no bytes — the '
          'capture pipeline is degraded by the interleaved stills',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason: 'a native error surfaced while interleaving stills + recording',
    );

    for (final p in photos) {
      _deleteIfPresent(p);
    }
    _deleteIfPresent(after.path);
    _deleteIfPresent(rec.path);
    if (rec.path != videoPath) _deleteIfPresent(videoPath);
  }

  // ── 4. recording × lens switch ─────────────────────────────────────────────

  /// Switching lens mid-recording must resolve to one of exactly two
  /// DOCUMENTED behaviours — rejected while recording, or the clip finalised
  /// before the swap — and never to a crash, a wedge or an orphaned
  /// unplayable file. Afterwards the new session must preview and record.
  ///
  /// Defect hunted: `startPreview()` (`CameraSession.kt:449`) is an unlocked
  /// check-then-`createCaptureSession` reachable from three threads, so a
  /// device switch racing the recorder's own session reconfigure can
  /// double-configure the camera; and the teardown path shares
  /// `onAppStop`'s (`CameraSession.kt:336`) habit of closing the session
  /// without stopping the recorder, which strands a clip with no `moov`.
  ///
  /// Returns false when the device exposes fewer than 2 cameras (caller
  /// skips).
  Future<bool> lensSwitchDuringRecording() async {
    if (cameraStore.devices.value.length < 2) return false;

    final original = _ctrl;
    final path = await _tempPath('lens');
    final beforeTid = cameraStore.activeTextureId.value;

    await original.startRecording(path);
    expect(original.isRecording, isTrue, reason: 'startRecording() did not arm');
    await pumpFor(const Duration(seconds: 2));

    cameraStore.toggleCamera();
    final switched = await _pumpWhile(
      () =>
          cameraStore.status.value == CameraStatus.running &&
          cameraStore.activeTextureId.value != beforeTid &&
          (cameraStore.activeController.value?.isInitialized ?? false),
      timeout: const Duration(seconds: 25),
    );

    final file = File(path);
    if (switched) {
      // Documented behaviour B: the clip is finalised, then the lens swaps.
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'the lens switch during recording discarded the clip entirely — '
            'neither documented outcome (reject-while-recording, or '
            'finalise-then-switch) happened',
      );
      final info = probeMp4(file);
      expect(
        info.isPlayable,
        isTrue,
        reason:
            'the lens switch stranded an unplayable clip ($info, '
            '${file.lengthSync()} bytes) — the session was torn down without '
            'stopping the recorder, exactly like CameraSession.onAppStop '
            '(CameraSession.kt:336), so no moov was written',
      );
      expect(
        cameraStore.activeController.value!.isRecording,
        isFalse,
        reason:
            'the freshly-opened session claims to be recording — recorder '
            'state leaked across the lens switch',
      );
    } else {
      // Documented behaviour A: the switch is refused while recording.
      expect(
        original.isRecording,
        isTrue,
        reason:
            'the lens switch was neither applied nor refused: the original '
            'session stopped recording but no new session came up — the '
            'unlocked startPreview() race (CameraSession.kt:449) wedged the '
            'camera',
      );
      expect(
        original.getSessionState().running,
        isTrue,
        reason:
            'the original session died on a refused lens switch — a refusal '
            'must leave the recording session untouched',
      );
      final rec = await awaitWithDeadline(
        original.stopRecording(),
        deadline: const Duration(seconds: 20),
        label: 'stopRecording() after a lens switch was refused',
      );
      final info = probeMp4(File(rec.path));
      expect(
        info.isPlayable,
        isTrue,
        reason:
            'the clip is unplayable ($info) after a refused lens switch — '
            'a refusal must not damage the in-flight recording',
      );
      _deleteIfPresent(rec.path);
    }
    _deleteIfPresent(path);

    await pumpUntil(
      () =>
          cameraStore.status.value == CameraStatus.running &&
          (cameraStore.activeController.value?.isInitialized ?? false),
      timeout: const Duration(seconds: 25),
      reason: 'no running preview after the mid-recording lens switch',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason: 'a native error surfaced from the mid-recording lens switch',
    );

    // The session must still be usable: record a fresh clip on it.
    final live = _ctrl;
    final freshPath = await _tempPath('lens_fresh');
    await live.startRecording(freshPath);
    await pumpFor(const Duration(seconds: 2));
    final fresh = await awaitWithDeadline(
      live.stopRecording(),
      deadline: const Duration(seconds: 20),
      label: 'stopRecording() of the clip recorded AFTER the lens switch',
    );
    final freshInfo = probeMp4(File(fresh.path));
    expect(
      freshInfo.isPlayable,
      isTrue,
      reason:
          'the session cannot record a playable clip after a mid-recording '
          'lens switch ($freshInfo) — the recorder was left in a broken '
          'state by the switch',
    );
    _deleteIfPresent(fresh.path);
    if (fresh.path != freshPath) _deleteIfPresent(freshPath);
    return true;
  }

  // ── 5. recording × live-setter storm ───────────────────────────────────────

  /// A user dragging zoom, flicking the torch and nudging exposure WHILE
  /// recording must not stall the preview or damage the clip.
  ///
  /// Defects hunted: every live setter reconfigures the repeating request, and
  /// the recorder shares that capture session — a setter storm that forces
  /// `startPreview()` (`CameraSession.kt:449`, unlocked
  /// check-then-`createCaptureSession`) to re-run mid-recording stalls frame
  /// delivery and can strand the clip. The frame-cadence budget
  /// ([FrameStreamReport.maxGapMs]) is the only observation that catches the
  /// stall; [Mp4Info] catches the stranded clip.
  Future<void> liveSettersDuringRecording() async {
    final c = _ctrl;
    final device = c.device;
    final path = await _tempPath('setters');

    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 600)); // pipeline warm-up
    final collector = FrameStatsCollector();
    collector.attach(c.frameStream);

    final wall = Stopwatch()..start();
    await c.startRecording(path);
    expect(c.isRecording, isTrue, reason: 'startRecording() did not arm');

    // Zoom sweep min → max → min (16 steps).
    const steps = 8;
    final span = device.maxZoom - device.minZoom;
    for (var i = 0; i <= steps; i++) {
      cameraStore.setZoom(device.minZoom + span * (i / steps));
      await pumpFor(const Duration(milliseconds: 150));
    }
    for (var i = steps; i >= 0; i--) {
      cameraStore.setZoom(device.minZoom + span * (i / steps));
      await pumpFor(const Duration(milliseconds: 150));
    }

    // Torch is device-dependent — a torchless lens must not fail the test.
    final hasTorch = device.hasTorch;
    if (hasTorch) {
      cameraStore.setTorch(true);
      await pumpFor(const Duration(milliseconds: 400));
      cameraStore.setTorch(false);
      await pumpFor(const Duration(milliseconds: 400));
    }

    cameraStore.setExposure(device.maxExposure / 2);
    await pumpFor(const Duration(milliseconds: 300));
    cameraStore.setExposure(device.minExposure / 2);
    await pumpFor(const Duration(milliseconds: 300));
    cameraStore.setExposure(0);

    await _padTo(wall, const Duration(seconds: 6));
    final rec = await awaitWithDeadline(
      c.stopRecording(),
      deadline: const Duration(seconds: 20),
      label: 'stopRecording() after a live-setter storm',
    );
    wall.stop();
    final report = await collector.stop();
    c.setFrameProcessing(enabled: false);

    if (hasTorch) {
      expect(
        c.torch,
        isFalse,
        reason: 'the torch was left ON after the storm — leaked torch state',
      );
    }

    final info = probeMp4(File(rec.path));
    expect(
      info.isPlayable,
      isTrue,
      reason:
          'the clip recorded through a live-setter storm is unplayable '
          '($info) — a setter forced a session reconfigure that tore the '
          'recorder down without finalising it (CameraSession.kt:449)',
    );
    expect(
      info.durationMs,
      isNotNull,
      reason: 'no mvhd duration in the clip ($info) — container is malformed',
    );
    expect(
      info.durationMs!,
      greaterThanOrEqualTo(5000),
      reason:
          'the clip is only ${info.durationMs}ms of a 6s recording window '
          '(plugin reported ${rec.durationMs}ms) — the setter storm starved '
          'the encoder',
    );
    expect(
      report.frameCount,
      greaterThan(10),
      reason:
          'almost no preview frames during the recording + setter storm '
          '($report) — frame delivery collapsed',
    );
    expect(
      report.maxGapMs,
      lessThan(900),
      reason:
          'the preview stalled for ${report.maxGapMs}ms during the '
          'recording + setter storm ($report) — a setter must never block '
          'frame delivery (unlocked startPreview(), CameraSession.kt:449)',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason: 'a live setter surfaced a native error while recording',
    );
    expect(
      c.getSessionState().running,
      isTrue,
      reason: 'the session is no longer running after the setter storm',
    );

    _deleteIfPresent(rec.path);
    if (rec.path != path) _deleteIfPresent(path);
  }

  // ── 6. recording × GPU filter × filtered stills ────────────────────────────

  /// Recording and still capture with a live GLSL filter, across two filter
  /// switches — the render path plus the filtered-still path plus the
  /// recorder, all at once.
  ///
  /// Defects hunted: `applyFilterToStill`
  /// (`android/.../NitraRenderer.kt:648-662`) allocates ~48 MB of RGBA plus a
  /// Bitmap that is never recycled for EVERY filtered photo, so the still
  /// pipeline degrades until capture stops returning — the trailing photo is
  /// the tripwire. `NitraRenderer.release()` (`NitraRenderer.kt:534`) calls
  /// `eglTerminate` on the SHARED default display, so a filter switch that
  /// recycles the renderer can take the preview's EGL context with it — the
  /// frame-cadence budget catches that.
  Future<void> filteredRecordingAndStills() async {
    final c = _ctrl;
    const first = 'INVERT';
    const second = 'GRAYSCALE';
    const third = 'SEPIA';
    expect(
      CameraStore.filters[first],
      isNotEmpty,
      reason: 'the $first preset must be a real (non-empty) GLSL shader',
    );

    cameraStore.setFilter(first);
    await pumpFor(const Duration(milliseconds: 600));

    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 600)); // pipeline warm-up
    final collector = FrameStatsCollector();
    collector.attach(c.frameStream);

    final photos = <String>[];
    final firstPath = await _tempPath('filter_a');
    final wall = Stopwatch()..start();
    await c.startRecording(firstPath);
    expect(c.isRecording, isTrue, reason: 'startRecording() did not arm');

    for (var i = 1; i <= 3; i++) {
      await pumpFor(const Duration(milliseconds: 900));
      final shot = await awaitWithDeadline(
        c.takePhoto(),
        deadline: const Duration(seconds: 15),
        label:
            'filtered takePhoto() #$i during a filtered recording — '
            'applyFilterToStill (NitraRenderer.kt:648-662) allocates ~48MB '
            'RGBA plus a never-recycled Bitmap per shot',
      );
      photos.add(shot.path);
    }

    await _padTo(wall, const Duration(seconds: 5));
    final firstRec = await awaitWithDeadline(
      c.stopRecording(),
      deadline: const Duration(seconds: 20),
      label: 'stopRecording() of the filtered clip',
    );
    wall.stop();
    final report = await collector.stop();
    c.setFrameProcessing(enabled: false);

    // Two filter switches — each one can recycle the renderer.
    cameraStore.setFilter(second);
    await pumpFor(const Duration(milliseconds: 600));
    cameraStore.setFilter(third);
    await pumpFor(const Duration(milliseconds: 600));

    final secondPath = await _tempPath('filter_b');
    await c.startRecording(secondPath);
    await pumpFor(const Duration(seconds: 2));
    final secondRec = await awaitWithDeadline(
      c.stopRecording(),
      deadline: const Duration(seconds: 20),
      label: 'stopRecording() of the clip recorded after two filter switches',
    );

    final firstInfo = probeMp4(File(firstRec.path));
    expect(
      firstInfo.isPlayable,
      isTrue,
      reason:
          'the clip recorded under the $first filter is unplayable '
          '($firstInfo) — the filtered render path broke recorder '
          'finalisation',
    );
    final secondInfo = probeMp4(File(secondRec.path));
    expect(
      secondInfo.isPlayable,
      isTrue,
      reason:
          'the clip recorded after switching $first → $second → $third is '
          'unplayable ($secondInfo) — a filter switch recycled the renderer '
          'and eglTerminate on the shared display (NitraRenderer.kt:534) '
          'took the recording surface with it',
    );

    for (var i = 0; i < photos.length; i++) {
      final f = File(photos[i]);
      expect(
        f.existsSync(),
        isTrue,
        reason:
            'filtered photo ${i + 1} of 3 wrote no file (${photos[i]}) — '
            'applyFilterToStill dropped the capture',
      );
      expect(
        f.lengthSync(),
        greaterThan(0),
        reason: 'filtered photo ${i + 1} of 3 is 0 bytes — no JPEG was encoded',
      );
    }

    expect(
      report.frameCount,
      greaterThan(10),
      reason:
          'almost no preview frames during the filtered recording ($report) '
          '— the GPU filter path starved frame delivery',
    );
    expect(
      report.maxGapMs,
      lessThan(900),
      reason:
          'the preview stalled for ${report.maxGapMs}ms during the filtered '
          'recording + filtered stills ($report) — each filtered still '
          'blocks the render thread with a ~48MB RGBA readback '
          '(NitraRenderer.kt:648-662)',
    );

    // Tripwire for the un-recycled 48MB bitmap path: after 3 filtered stills,
    // two clips and two filter switches, capture must still return.
    final trailing = await awaitWithDeadline(
      c.takePhoto(),
      deadline: const Duration(seconds: 15),
      label:
          'takePhoto() after 3 filtered stills, 2 filtered clips and 2 '
          'filter switches — the never-recycled Bitmap in applyFilterToStill '
          '(NitraRenderer.kt:648-662) degrades the still pipeline until '
          'capture stops returning',
    );
    final trailingFile = File(trailing.path);
    expect(
      trailingFile.existsSync() && trailingFile.lengthSync() > 0,
      isTrue,
      reason:
          'the trailing still produced no bytes — the filtered-still path '
          'left the capture pipeline degraded',
    );
    expect(
      cameraStore.errorMessage.value,
      isNull,
      reason: 'a native error surfaced from the filtered recording flow',
    );
    expect(
      c.getSessionState().running,
      isTrue,
      reason: 'the session is no longer running after the filtered flow',
    );

    cameraStore.setFilter('NORMAL'); // restore
    await pumpFor(const Duration(milliseconds: 300));

    for (final p in photos) {
      _deleteIfPresent(p);
    }
    _deleteIfPresent(trailing.path);
    _deleteIfPresent(firstRec.path);
    if (firstRec.path != firstPath) _deleteIfPresent(firstPath);
    _deleteIfPresent(secondRec.path);
    if (secondRec.path != secondPath) _deleteIfPresent(secondPath);
  }

  // ── 7. recording × audio track ─────────────────────────────────────────────

  /// `audio: true` must actually mux a `soun` track, and `audio: false` must
  /// actually omit it. The whole suite otherwise never records with audio, so
  /// the microphone path is completely unverified.
  ///
  /// Defect hunted: `VideoOutput.kt:167` calls `setAudioSource(MIC)`
  /// UNCONDITIONALLY — no permission check and no video-only fallback — so on
  /// a device where the mic is unavailable `MediaRecorder.start()` throws,
  /// leaving `isRecording = true` plus an orphan file. Mirrored by the
  /// opposite failure: the flag being ignored, so `audio: false` still muxes
  /// audio (or `audio: true` silently does not).
  ///
  /// RECORD_AUDIO is already granted: `camera.openAppToPreview()` walks BOTH
  /// system dialogs natively (`Module.acceptPermissionDialogs`).
  Future<void> recordingWithAudioTrack() async {
    final device =
        cameraStore.currentDevice.value ?? cameraStore.devices.value.first;

    CameraController? current;
    var closings = 0;
    final events = <CameraSessionEvent>[];

    // Same raw-mount idiom as CameraWidget.verifyDeclarativeLifecycle: the
    // audio flag is a CameraView/CameraController construction parameter, so
    // it can only be exercised by owning the session.
    Widget build({required bool audio}) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: CameraView(
          device: device,
          audio: audio,
          previewMode: PreviewMode.texture,
          onInitialized: (c) => current = c,
          onClosing: () => closings++,
          onEvent: events.add,
        ),
      );
    }

    Future<Mp4Info> recordClip({
      required bool audio,
      required Duration length,
      required String tag,
    }) async {
      final c = current!;
      final path = await _tempPath(tag);
      await c.startRecording(path);
      expect(
        c.isRecording,
        isTrue,
        reason:
            'startRecording(audio: $audio) did not arm the recorder — '
            'setAudioSource(MIC) is unconditional (VideoOutput.kt:167) and '
            'a rejected mic leaves no armed recorder',
      );
      await pumpFor(length);
      final rec = await awaitWithDeadline(
        c.stopRecording(),
        deadline: const Duration(seconds: 20),
        label: 'stopRecording() of the audio: $audio clip',
      );
      expect(
        c.isRecording,
        isFalse,
        reason:
            'isRecording is still true after stopRecording(audio: $audio) — '
            'a failed start leaves the flag set (VideoOutput.kt:167) and '
            'blocks every later recording',
      );
      final info = probeMp4(File(rec.path));
      _deleteIfPresent(rec.path);
      if (rec.path != path) _deleteIfPresent(path);
      return info;
    }

    // Hand the camera back before opening our own session: the example app's
    // CameraView disposes its controller asynchronously, and a second open
    // racing that teardown is a "device busy" HAL rejection on single-session
    // hardware — a setup artefact, not the defect under test.
    await $.tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await pumpFor(const Duration(milliseconds: 1200));

    await $.tester.pumpWidget(build(audio: true));
    await pumpUntil(
      () => current?.isInitialized ?? false,
      timeout: const Duration(seconds: 25),
      reason: 'CameraView(audio: true) never published an initialized session',
    );
    await pumpFor(const Duration(milliseconds: 800)); // let AE/AF settle

    final withAudio = await recordClip(
      audio: true,
      length: const Duration(seconds: 4),
      tag: 'audio_on',
    );
    expect(
      withAudio.isPlayable,
      isTrue,
      reason:
          'the audio: true clip is unplayable ($withAudio) — an unconditional '
          'setAudioSource(MIC) (VideoOutput.kt:167) that fails leaves an '
          'orphan file instead of a finalised one',
    );
    expect(
      withAudio.hasVideoTrack,
      isTrue,
      reason: 'the audio: true clip has no video track ($withAudio)',
    );
    expect(
      withAudio.hasAudioTrack,
      isTrue,
      reason:
          'audio: true muxed NO soun track ($withAudio) — the audio flag is '
          'ignored, so every "recording with audio" is silent',
    );
    expect(
      withAudio.trackCount,
      greaterThanOrEqualTo(2),
      reason:
          'the audio: true clip carries only ${withAudio.trackCount} track(s) '
          '($withAudio) — audio + video means at least 2',
    );
    expect(
      withAudio.durationMs,
      isNotNull,
      reason: 'no mvhd duration in the audio: true clip ($withAudio)',
    );
    expect(
      withAudio.durationMs!,
      greaterThanOrEqualTo(3500),
      reason:
          'the audio: true clip is only ${withAudio.durationMs}ms of a 4s '
          'recording — the muxer dropped the tail',
    );

    // Flip the flag: the session reopens (audio is a lifecycle prop).
    final beforeClosings = closings;
    current = null;
    await $.tester.pumpWidget(build(audio: false));
    await pumpUntil(
      () => closings > beforeClosings && (current?.isInitialized ?? false),
      timeout: const Duration(seconds: 25),
      reason:
          'CameraView never reopened the session for audio: false — the '
          'audio flag must be a lifecycle prop',
    );
    await pumpFor(const Duration(milliseconds: 800));

    final withoutAudio = await recordClip(
      audio: false,
      length: const Duration(seconds: 3),
      tag: 'audio_off',
    );
    expect(
      withoutAudio.isPlayable,
      isTrue,
      reason: 'the audio: false clip is unplayable ($withoutAudio)',
    );
    expect(
      withoutAudio.hasVideoTrack,
      isTrue,
      reason: 'the audio: false clip has no video track ($withoutAudio)',
    );
    expect(
      withoutAudio.hasAudioTrack,
      isFalse,
      reason:
          'audio: false STILL muxed a soun track ($withoutAudio) — the flag '
          'does not reach the recorder, which calls setAudioSource(MIC) '
          'unconditionally (VideoOutput.kt:167); it also means every '
          'video-only recording needs RECORD_AUDIO to succeed',
    );

    expect(
      events.every((e) => !e.isError),
      isTrue,
      reason:
          'the audio recording flow raised error events '
          '(${events.where((e) => e.isError).map((e) => e.message).toList()})',
    );

    // Unmount so the raw session is disposed with the test.
    await $.tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await pumpFor(const Duration(milliseconds: 800));
  }
}
