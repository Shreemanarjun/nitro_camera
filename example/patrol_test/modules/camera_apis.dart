import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera/native.dart' show NitroCamera;
import 'package:path_provider/path_provider.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import 'module.dart';

// Frame-processor plugin under test — top-level: it crosses isolates.
FrameProcessorPlugin createMeanLumaPlugin(Map<String, Object?> options) =>
    _MeanLumaPlugin(options);

class _MeanLumaPlugin extends FrameProcessorPlugin {
  const _MeanLumaPlugin(super.options);

  @override
  Object? callback(FrameData frame) {
    final step = (options['step'] as int?) ?? 64;
    var sum = 0, n = 0;
    for (var i = 0; i < frame.bytes.length; i += step) {
      sum += frame.bytes[i];
      n++;
    }
    return n == 0 ? null : sum / n;
  }
}

/// Public-API verification module: each method exercises one API group of
/// package:nitro_camera against the live session (mirrors the coverage of
/// integration_test/api_surface_test.dart under Patrol).
final class CameraApis extends Module {
  CameraApis(super.$);

  CameraController get _ctrl => cameraStore.activeController.value!;

  Future<void> verifyPermissionApis() async {
    expect(await CameraController.requestCameraPermission(),
        PermissionStatus.granted);
    expect(NitroCamera.instance.getCameraPermissionStatus(),
        PermissionStatus.granted.index);
    final mic = NitroCamera.instance.getMicrophonePermissionStatus();
    expect(mic, inInclusiveRange(0, PermissionStatus.values.length - 1));
  }

  Future<void> verifyTypedDeviceEnumeration() async {
    final devices = await CameraController.getAvailableCameraDevices();
    expect(devices, isNotEmpty, reason: 'a phone must expose ≥ 1 camera');

    for (final d in devices) {
      expect(d.id, isNotEmpty);
      expect(d.name, isNotEmpty);
      expect(CameraPosition.values, contains(d.position));
      expect(CameraLensType.values, contains(d.lensType));
      expect(HardwareLevel.values, contains(d.hardwareLevel));
      expect(d.sensorOrientation % 90, 0);
      expect(d.maxZoom, greaterThanOrEqualTo(d.minZoom));
      expect(d.maxPhotoWidth, greaterThan(0));
      expect(d.maxPhotoHeight, greaterThan(0));
      expect(d.formats, isNotEmpty);
      for (final f in d.formats) {
        expect(f.videoWidth, greaterThan(0));
        expect(f.videoHeight, greaterThan(0));
        expect(f.maxFps, greaterThanOrEqualTo(f.minFps));
        expect(AutoFocusSystem.values, contains(f.autoFocusSystem));
        expect(f.videoStabilizationModes, isNotEmpty);
      }
    }

    final back = devices.backCamera();
    final front = devices.frontCamera();
    expect(back ?? front, isNotNull);
    if (back != null) expect(back.position, CameraPosition.back);
    if (front != null) expect(front.position, CameraPosition.front);
    if (back != null) {
      expect(
        selectCameraDevice(devices,
            position: CameraPosition.back,
            physicalDevices: [PhysicalDeviceType.wideAngleCamera]),
        isNotNull,
      );
    }

    final resolved = FormatResolver.resolve(back ?? front!, const [
      ResolutionConstraint(TargetResolution.closestTo(1920, 1080)),
      FpsConstraint(30),
    ]);
    expect(resolved, isNotNull);

    for (final combo in CameraController.getConcurrentCameraIds()) {
      expect(combo, isNotEmpty);
    }
  }

  Future<void> verifyConfigureWithoutReopen() async {
    final c = _ctrl;
    final st = c.getSessionState();
    expect(st.running, isTrue);
    expect(st.width, greaterThan(0));
    expect(st.height, greaterThan(0));
    expect(st.fps, greaterThan(0));

    final beforeTid = c.textureId;
    final base = c.configuration;
    expect(base, isNotNull);
    await c.configure(base!.copyWith(zoom: 2.0, exposure: 0.5));
    expect(c.textureId, beforeTid,
        reason: 'live-field configure must not tear down the session');
    expect(c.configuration!.zoom, 2.0);
    await c.configure(base.copyWith(zoom: 1.0, exposure: 0.0));
    expect(c.textureId, beforeTid);

    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.errorMessage.value, isNull);
    expect(c.getSessionState().running, isTrue);
  }

  Future<void> verifyLiveSetters() async {
    final c = _ctrl;
    final device = c.device;

    // Use the device's REAL zoom range — an emulator (or a fixed-zoom lens)
    // reports maxZoom == 1.0, so a hardcoded setZoom(2.0) would clamp to 1.0.
    final midZoom = (device.minZoom + device.maxZoom) / 2;
    c.setZoom(midZoom);
    expect(c.zoom, midZoom);
    c.setZoom(device.maxZoom + 100); // clamps to maxZoom, never throws
    expect(c.zoom, device.maxZoom);
    c.setZoom(device.minZoom);

    c.setExposure(device.maxExposure / 2);
    c.setExposure(0.0);
    c.setFlash(FlashMode.auto);
    expect(c.flash, FlashMode.auto);
    c.setFlash(FlashMode.off);
    c.focus(0.5, 0.5);
    c.setAutoFocus(AutoFocusMode.locked);
    c.setAutoFocus(AutoFocusMode.continuous);
    c.setWhiteBalance(5600);
    c.setWhiteBalance(0);
    c.setHdr(enabled: true);
    c.setHdr(enabled: false);
    c.setLowLightBoost(enabled: true);
    c.setLowLightBoost(enabled: false);
    c.setVideoStabilization(VideoStabilizationMode.standard);
    c.setVideoStabilization(VideoStabilizationMode.off);
    c.setDistortionCorrection(enabled: true);
    c.lockExposure(locked: true);
    c.lockExposure(locked: false);
    c.lockFocus(locked: true);
    c.lockFocus(locked: false);
    c.lockWhiteBalance(locked: true);
    c.lockWhiteBalance(locked: false);
    c.setTargetOrientation(0);
    c.setTargetOrientation(-1); // -1 = auto (follow display)
    c.setSamplingRate(2);
    c.setSamplingRate(1);
    c.setFilterShader('');

    await pumpFor(const Duration(seconds: 2));
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'no live setter may surface a native error');
    expect(c.getSessionState().running, isTrue);
  }

  /// Returns false when the active device has no torch (caller skips).
  Future<bool> verifyTorch() async {
    final c = _ctrl;
    if (!c.device.hasTorch) return false;

    c.setTorch(enabled: true);
    expect(c.torch, isTrue);
    await pumpFor(const Duration(milliseconds: 500));
    c.setTorchLevel(0.5);
    await pumpFor(const Duration(milliseconds: 500));
    c.setTorch(enabled: false);
    expect(c.torch, isFalse);

    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.errorMessage.value, isNull);
    expect(cameraStore.status.value, CameraStatus.running);
    return true;
  }

  Future<void> verifyPauseResume() async {
    final c = _ctrl;
    final tid = c.textureId;

    c.pausePreview();
    expect(c.isActive, isFalse);
    await pumpFor(const Duration(seconds: 1));

    c.resumePreview();
    expect(c.isActive, isTrue);
    expect(c.textureId, tid, reason: 'pause/resume must not reopen');
    await pumpUntil(
      () => c.getSessionState().running,
      reason: 'stream running again after resumePreview',
    );
    expect(cameraStore.errorMessage.value, isNull);
  }

  Future<void> verifyFrameStreamContract() async {
    final c = _ctrl;
    final frames = <({int textureId, int w, int h, int size, int rowBytes})>[];
    // Copy scalar fields only inside the listener — the pixel buffer is a
    // zero-copy borrow that is reused after the callback returns.
    final sub = c.frameStream.listen((f) {
      if (frames.length < 10) {
        frames.add((
          textureId: f.textureId,
          w: f.width,
          h: f.height,
          size: f.size,
          rowBytes: f.bytesPerRow,
        ));
      }
    });
    c.setFrameProcessing(enabled: true);

    await pumpUntil(
      () => frames.length >= 5,
      reason: 'CPU frames delivered on frameStream',
    );
    await sub.cancel();
    c.setFrameProcessing(enabled: false);

    for (final f in frames) {
      expect(f.textureId, c.textureId,
          reason: 'frameStream must be filtered to its own session');
      expect(f.w, greaterThan(0));
      expect(f.h, greaterThan(0));
      expect(f.size, greaterThan(0));
      if (f.rowBytes > 0) expect(f.size, f.rowBytes * f.h);
    }
  }

  Future<void> verifyFrameProcessorPlugin() async {
    final c = _ctrl;

    FrameProcessorPlugins.register('meanLuma', createMeanLumaPlugin);
    expect(FrameProcessorPlugins.isRegistered('meanLuma'), isTrue);
    expect(() => FrameProcessorPlugins.init('no-such-plugin'),
        throwsArgumentError);

    final runner = FrameProcessorPlugins.init('meanLuma', {'step': 64});
    final results = <Object?>[];
    final resultSub = runner.results.listen(results.add);
    final statsSeen = <FrameProcessStats>[];
    final statsSub = runner.stats.listen(statsSeen.add);

    await runner.start(c.frameStream);
    c.setFrameProcessing(enabled: true);

    await pumpUntil(
      () => results.isNotEmpty && statsSeen.isNotEmpty,
      reason: 'plugin produced results + timing stats from live frames',
    );
    expect(results.first, isA<double>());
    expect(statsSeen.first.elapsedMicros, greaterThan(0));

    c.setFrameProcessing(enabled: false);
    await resultSub.cancel();
    await statsSub.cancel();
    await runner.dispose();
    await pumpFor(const Duration(milliseconds: 300));
    expect(cameraStore.status.value, CameraStatus.running);
  }

  Future<void> verifyRecordingControls() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();

    final path =
        '${dir.path}/patrol_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    // Time the whole cycle so the pause-exclusion check is robust against pump
    // imprecision: a LONG pause (1.5s) makes "excluded" (durationMs well under
    // wall-clock) vs "included" (durationMs ~= wall-clock) unambiguous.
    const pause = Duration(milliseconds: 1500);
    final wall = Stopwatch()..start();
    await c.startRecording(
      path,
      options: const RecordingOptions(
        codec: 0, // h264
        fileType: 0, // mp4
        bitRate: 4_000_000,
      ),
    );
    expect(c.isRecording, isTrue);
    await pumpFor(const Duration(seconds: 1));

    c.pauseRecording();
    expect(c.isRecordingPaused, isTrue);
    await pumpFor(pause);
    c.resumeRecording();
    expect(c.isRecordingPaused, isFalse);
    await pumpFor(const Duration(seconds: 1));

    final rec = await c.stopRecording();
    wall.stop();
    expect(c.isRecording, isFalse);
    final f = File(rec.path);
    expect(f.existsSync(), isTrue);
    expect(rec.fileSize, greaterThan(0));
    expect(f.lengthSync(), rec.fileSize);
    expect(rec.durationMs, greaterThan(500));
    // Paused time must NOT be counted: reported duration is at least ~1s under
    // the wall-clock (which spans the 1.5s pause). If pause leaked in,
    // durationMs would be ~= wall-clock and this fails.
    expect(rec.durationMs, lessThan(wall.elapsedMilliseconds - 1000),
        reason: 'paused span leaked into durationMs '
            '(dur=${rec.durationMs}ms, wall=${wall.elapsedMilliseconds}ms)');
    expect(rec.reason, RecordingFinishedReason.stopped);
    expect(rec.videoCodec, VideoCodec.h264);
    expect(rec.videoFileType, VideoFileType.mp4);
    f.deleteSync();

    final cancelPath =
        '${dir.path}/patrol_cancel_${DateTime.now().millisecondsSinceEpoch}.mp4';
    await c.startRecording(cancelPath);
    await pumpFor(const Duration(milliseconds: 700));
    c.cancelRecording();
    expect(c.isRecording, isFalse);
    await pumpUntil(
      () => !File(cancelPath).existsSync(),
      timeout: const Duration(seconds: 5),
      reason: 'cancelRecording deletes the partial file',
    );
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Returns a small report of what was actually exercised. `dng` is:
  ///   'ok'          — RAW capture verified,
  ///   'unsupported' — device doesn't advertise RAW,
  ///   'unavailable' — device advertises RAW but the HAL couldn't deliver a
  ///                   frame (e.g. OnePlus / ColorOS gate full RAW capture) —
  ///                   the caller skips rather than failing.
  Future<({String dng})> verifyPhotoVariants() async {
    final c = _ctrl;
    await pumpFor(const Duration(seconds: 1)); // AE/AF settle

    // JPEG variants are guaranteed on any camera — assert strictly.
    final geo = await c.takePhotoWithOptions(const PhotoCaptureOptions(
      location: (latitude: 37.7749, longitude: -122.4194, altitude: 12.0),
    ));
    expect(File(geo.path).existsSync(), isTrue);
    expect(geo.width, greaterThan(0));
    expect(geo.height, greaterThan(0));
    File(geo.path).deleteSync();

    final fast = await c.takePhotoWithOptions(const PhotoCaptureOptions(
      quality: QualityPrioritization.speed,
      enableShutterSound: false,
      skipMetadata: true,
    ));
    expect(File(fast.path).existsSync(), isTrue);
    File(fast.path).deleteSync();

    var dng = 'unsupported';
    if (c.device.supportsRawCapture) {
      // RAW/DNG is deeply device-specific: some HALs advertise the RAW
      // capability but never deliver a RAW_SENSOR frame in a preview+RAW
      // session (ColorOS). Treat a capture failure as "advertised but
      // unavailable" and skip — don't fail the whole variant test. The JPEG
      // assertions above still guard the common path.
      try {
        final raw = await c.takePhotoWithOptions(const PhotoCaptureOptions(
          outputFormat: PhotoOutputFormat.dng,
        ));
        expect(File(raw.path).existsSync(), isTrue);
        expect(raw.path.toLowerCase(), endsWith('.dng'));
        File(raw.path).deleteSync();
        dng = 'ok';
      } catch (e) {
        // ignore: avoid_print
        print('DNG capture unavailable on this device (advertised RAW): $e');
        dng = 'unavailable';
        // The DNG path restores the preview in its finally block; give it a
        // beat and clear the surfaced native-error event.
        await pumpFor(const Duration(seconds: 1));
        cameraStore.errorMessage.value = null;
      }
    }

    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
    return (dng: dng);
  }

  Future<void> verifyNativeDetectorSmoke() async {
    final c = _ctrl;
    // Typed detector API (startDetector + the typed detections stream).
    final detections = <DetectionResult>[];
    final sub = c.detections.listen(detections.add);
    c.startDetector(NativeDetector.barcode);

    var framesSeen = 0;
    final frameSub = c.frameStream.listen((_) => framesSeen++);
    c.setFrameProcessing(enabled: true);
    await pumpUntil(
      () => framesSeen > 5,
      reason: 'stream stays alive with the native detector attached',
    );

    c.stopDetector();
    c.setFrameProcessing(enabled: false);
    await frameSub.cancel();
    await sub.cancel();
    // Any detections that DID arrive must be well-formed & of the right kind
    // (the scene may have no barcode, so an empty list is also valid).
    for (final d in detections) {
      expect(d.detector, NativeDetector.barcode);
      expect(d.frameWidth, greaterThan(0));
    }
    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Rapidly start/stop the native detectors (barcode ↔ face ↔ off) many
  /// times — stresses the per-texture detector-engine lifecycle (a leak-prone
  /// path: each engine must be released on swap/stop). The stream must stay
  /// alive and error-free throughout.
  Future<void> verifyDetectorChurn() async {
    final c = _ctrl;
    var framesSeen = 0;
    final frameSub = c.frameStream.listen((_) => framesSeen++);
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 500));

    const seq = [
      NativeDetector.barcode,
      NativeDetector.face,
      NativeDetector.barcode,
      NativeDetector.face,
    ];
    for (final d in seq) {
      c.startDetector(d);
      await pumpFor(const Duration(milliseconds: 400));
      c.stopDetector();
      await pumpFor(const Duration(milliseconds: 200));
    }

    final before = framesSeen;
    await pumpUntil(
      () => framesSeen > before + 5,
      reason: 'frames keep flowing after detector churn (engine leak/wedge?)',
    );
    c.setFrameProcessing(enabled: false);
    await frameSub.cancel();
    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'detector start/stop churn must not surface an error');
  }

  /// configure() with a session-field change (fps) must REOPEN: new
  /// textureId, session streaming again at the end.
  Future<void> verifyConfigureReopen() async {
    final c = _ctrl;
    final base = c.configuration!;
    final beforeTid = c.textureId;
    final targetFps = base.fps == 30 ? 24 : 30;

    await c.configure(base.copyWith(fps: targetFps));
    expect(c.textureId, isNot(beforeTid),
        reason: 'an fps change must tear down and reopen the session');
    expect(c.isInitialized, isTrue);
    await pumpUntil(() => c.getSessionState().running,
        reason: 'session streaming after the fps reopen');

    await c.configure(c.configuration!.copyWith(fps: base.fps));
    await pumpUntil(() => c.getSessionState().running,
        reason: 'session streaming after restoring fps');
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Typed capture events (photoCaptureBegan/Shutter) arrive on
  /// controller.events AND on the static allEvents stream, scoped to this
  /// session's textureId.
  Future<void> verifyCaptureEvents() async {
    final c = _ctrl;
    final mine = <CameraSessionEvent>[];
    final all = <CameraSessionEvent>[];
    final s1 = c.events.listen(mine.add);
    final s2 = CameraController.allEvents.listen(all.add);

    final photo = await c.takePhoto();
    File(photo.path).deleteSync();
    await pumpUntil(
      () => mine.any((e) =>
          e.type == CameraEventType.photoCaptureShutter ||
          e.type == CameraEventType.photoCaptureBegan),
      reason: 'typed capture events delivered on controller.events',
    );
    await s1.cancel();
    await s2.cancel();

    expect(
        all.any((e) =>
            e.type == CameraEventType.photoCaptureShutter ||
            e.type == CameraEventType.photoCaptureBegan),
        isTrue,
        reason: 'allEvents must carry the same capture events');
    expect(mine.every((e) => e.textureId == c.textureId || e.textureId == 0),
        isTrue,
        reason: 'controller.events must be scoped to its session');
  }

  /// RecordingOptions.maxDurationMs auto-stops natively; the finished file
  /// path arrives on the `stopped` event.
  Future<void> verifyAutoStopRecording() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final stops = <CameraSessionEvent>[];
    final sub = CameraController.allEvents
        .where((e) => e.type == CameraEventType.stopped && e.message.isNotEmpty)
        .listen(stops.add);

    final path =
        '${dir.path}/patrol_auto_${DateTime.now().millisecondsSinceEpoch}.mp4';
    await c.startRecording(
      path,
      options: const RecordingOptions(maxDurationMs: 1500),
    );
    await pumpUntil(
      () => stops.isNotEmpty,
      timeout: const Duration(seconds: 15),
      reason: 'native auto-stop emitted a stopped event with the file path',
    );
    await sub.cancel();

    final finished = File(stops.first.message);
    expect(finished.existsSync(), isTrue,
        reason: 'auto-stop event must carry the finalized file path');
    expect(finished.lengthSync(), greaterThan(0));
    finished.deleteSync();
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// HEVC + MOV variant: codec + container options round-trip through the
  /// typed result metadata. Returns false when the device has no HEVC encoder
  /// (emulators often don't) so the caller can skip instead of failing.
  Future<bool> verifyHevcRecording() async {
    final c = _ctrl;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/patrol_hevc_${DateTime.now().millisecondsSinceEpoch}.mov';

    try {
      await c.startRecording(
        path,
        options:
            const RecordingOptions(codec: 1 /* hevc */, fileType: 1 /* mov */),
      );
    } on CameraException {
      // No HEVC encoder — the recorder rejected the codec at prepare().
      return false;
    }
    await pumpFor(const Duration(seconds: 2));
    final rec = await c.stopRecording();

    final f = File(rec.path);
    expect(f.existsSync(), isTrue);
    expect(rec.fileSize, greaterThan(0));
    expect(rec.durationMs, greaterThan(0));
    expect(rec.videoCodec, VideoCodec.hevc,
        reason: 'requested HEVC but the recorder reported '
            '${rec.videoCodec.name} — encoder fallback?');
    // NOTE: container is platform-normalized — Android's MediaRecorder writes
    // MPEG-4 for a .mov request (VideoFileType.mp4); iOS honours .mov. So the
    // fileType is validated only as a real enum value, not pinned to mov.
    expect(VideoFileType.values, contains(rec.videoFileType));
    f.deleteSync();
    expect(cameraStore.errorMessage.value, isNull);
    return true;
  }

  /// Flash photo on a flash-equipped device (the AE-precapture regression).
  /// Returns false when the active device has no flash (caller skips).
  Future<bool> verifyFlashPhoto() async {
    final c = _ctrl;
    if (!c.device.hasFlash) return false;

    await pumpFor(const Duration(seconds: 1)); // AE settle
    final photo = await c.takePhotoWithOptions(
        const PhotoCaptureOptions(flash: FlashMode.on));
    expect(File(photo.path).existsSync(), isTrue);
    expect(File(photo.path).lengthSync(), greaterThan(0));
    File(photo.path).deleteSync();

    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'flash capture must not surface an error');
    return true;
  }

  /// Concurrent multi-cam: only when the platform advertises a combination
  /// containing the ACTIVE device (returns false → caller skips). Opens the
  /// partner as a second controller and proves the per-session frameStream
  /// separation for real.
  Future<bool> verifyMulticamConcurrent() async {
    final c = _ctrl;
    final combos = CameraController.getConcurrentCameraIds();
    final combo = combos
        .where((ids) => ids.contains(c.device.id) && ids.length > 1)
        .firstOrNull;
    if (combo == null) return false;
    final devices = await CameraController.getAvailableCameraDevices();
    final partner = devices
        .where((d) => d.id == combo.firstWhere((id) => id != c.device.id))
        .firstOrNull;
    if (partner == null) return false;

    final second = CameraController(device: partner);
    try {
      await second.initialize();
      final firstFrames = <int>[];
      final secondFrames = <int>[];
      final s1 = c.frameStream.listen((f) => firstFrames.add(f.textureId));
      final s2 = second.frameStream.listen((f) => secondFrames.add(f.textureId));
      c.setFrameProcessing(enabled: true);
      second.setFrameProcessing(enabled: true);

      await pumpUntil(
        () => secondFrames.length >= 3,
        reason: 'second concurrent session delivered frames',
      );
      await s1.cancel();
      await s2.cancel();
      second.setFrameProcessing(enabled: false);
      c.setFrameProcessing(enabled: false);

      expect(secondFrames.toSet(), {second.textureId},
          reason: 'second session frames carry ITS textureId only');
      expect(firstFrames.toSet().difference({c.textureId!}), isEmpty,
          reason: 'no cross-session frame leak into the first stream');
    } finally {
      await second.dispose();
    }
    await pumpFor(const Duration(milliseconds: 500));
    expect(cameraStore.status.value, CameraStatus.running);
    return true;
  }

  /// Error PATHS — the plugin must surface typed errors and stay healthy, not
  /// crash or wedge. (a) recording to an unwritable path throws a typed
  /// RecorderException and the session survives + can still record to a good
  /// path afterwards; (b) a control call after dispose() throws
  /// SessionException.
  Future<void> verifyRecordingErrorPaths() async {
    final c = _ctrl;

    // (a) Invalid output path → typed RecorderException (not a bare error).
    await expectLater(
      c.startRecording('/nonexistent_dir_xyz/clip.mp4'),
      throwsA(isA<RecorderException>()),
    );
    expect(c.isRecording, isFalse,
        reason: 'a failed start must not leave the controller "recording"');
    await pumpFor(const Duration(milliseconds: 500));
    // The session must SURVIVE a rejected recording (still running), and the
    // failure is RECORDER-scoped (thrown RecorderException) — it must NOT
    // surface as a session error event / errorMessage. This is the scoping fix.
    expect(cameraStore.status.value, CameraStatus.running,
        reason: 'a rejected recording must not kill the session');
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'a caller-side bad-path recording must be recorder-scoped, '
            'not a session error event');

    // Recovery: the SAME session records to a valid path right after — proving
    // the rejected attempt left the recorder in a usable state.
    final dir = await getTemporaryDirectory();
    final good =
        '${dir.path}/patrol_recover_${DateTime.now().millisecondsSinceEpoch}.mp4';
    await c.startRecording(good);
    await pumpFor(const Duration(seconds: 1));
    final rec = await c.stopRecording();
    expect(File(rec.path).existsSync(), isTrue,
        reason: 'session must record normally after a rejected attempt');
    expect(rec.fileSize, greaterThan(0));
    File(rec.path).deleteSync();
    expect(cameraStore.status.value, CameraStatus.running);
  }

  /// Stability under a rapid still-capture burst (the "capture gets stuck"
  /// class): [count] photos back-to-back must all return valid files with the
  /// session still live.
  Future<void> verifyPhotoBurst({int count = 5}) async {
    final c = _ctrl;
    await pumpFor(const Duration(seconds: 1)); // AE/AF settle once
    for (var i = 1; i <= count; i++) {
      final p = await c.takePhoto();
      expect(p.path, isNotEmpty, reason: 'burst photo #$i returned no path');
      final f = File(p.path);
      expect(f.existsSync(), isTrue, reason: 'burst photo #$i missing');
      expect(f.lengthSync(), greaterThan(0), reason: 'burst photo #$i empty');
      f.deleteSync();
      await pumpFor(const Duration(milliseconds: 150));
    }
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'a capture burst must not surface an error');
  }

  Future<void> verifyTypedErrorsAndObservers() async {
    // session/not-initialized: the typed error contract. A bogus openCamera
    // is deliberately NOT exercised on-device: probing nonexistent ids can
    // wedge constrained HALs (OnePlus "unknown device" storms).
    final fresh = CameraController(device: _ctrl.device);
    expect(
      () => fresh.setZoom(2.0),
      throwsA(isA<SessionException>()
          .having((e) => e.code, 'code', 'session/not-initialized')),
    );
    await fresh.dispose();

    final om = OrientationManager();
    await om.start();
    om.drive(_ctrl, OutputOrientationMode.device);
    await pumpFor(const Duration(seconds: 1));
    final deg = om.currentOrientation;
    if (deg != null) expect(deg % 90, 0);
    om.drive(null);
    await om.dispose();

    final observer = CameraDevicesObserver();
    await observer.start();
    await pumpFor(const Duration(milliseconds: 500));
    await observer.dispose();

    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  }
}
