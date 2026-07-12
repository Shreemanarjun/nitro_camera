// Full public-API surface integration suite — exercises every high-level API
// of package:nitro_camera against the real camera HAL.
//
// Run on a connected device:
//   cd example && flutter test integration_test/api_surface_test.dart -d <serial>
//
// Coverage map (complements the focused suites):
//   1. permissions (status queries + request round-trip)
//   2. typed device enumeration, selectors, format resolver, concurrent IDs
//   3. session state + declarative configure() (no-reopen) + read-back
//   4. every imperative live setter (zoom/exposure/flash/WB/HDR/locks/…)
//   5. torch + torch level (hasTorch-gated)
//   6. preview pause/resume (setActive)
//   7. frameStream: session filtering + CameraFrame zero-copy contract
//   8. frame-processor plugin registry end-to-end (worker isolate)
//   9. recording controls: options, pause/resume, result metadata, cancel
//  10. photo option variants (geotag, silent, speed; DNG when supported)
//  11. native detector smoke (barcode on/off keeps the stream alive)
//  12. typed errors + orientation manager / hot-plug observer lifecycles
//
// camera_lifecycle_test.dart owns switching/reopen storms;
// capture_latency_test.dart owns latency budgets; resolution_4k_test.dart
// owns the 4K stream. This suite owns API breadth.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera/native.dart' show NitroCamera;
import 'package:path_provider/path_provider.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import 'support/harness.dart';

// ── Frame-processor plugin under test (must be top-level: crosses isolates) ──

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installSemanticsFlakeFilter();

  CameraController ctrl() => cameraStore.activeController.value!;

  testWidgets(
    '1. permissions: status queries agree with the request path',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);

      // bootApp guarantees camera permission; the typed request API must agree
      // and the raw status queries must report granted (1).
      expect(
        await CameraController.requestCameraPermission(),
        PermissionStatus.granted,
      );
      expect(
        NitroCamera.instance.getCameraPermissionStatus(),
        PermissionStatus.granted.index,
      );
      // Microphone: the store's boot flow doesn't force it, so only assert the
      // query returns a decodable status (the request may show a dialog on a
      // fresh install — accept manually the first time).
      final mic = NitroCamera.instance.getMicrophonePermissionStatus();
      expect(mic, inInclusiveRange(0, PermissionStatus.values.length - 1));
    },
  );

  testWidgets(
    '2. typed device enumeration, selectors and format resolver',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);

      final devices = await CameraController.getAvailableCameraDevices();
      expect(devices, isNotEmpty, reason: 'a phone must expose ≥ 1 camera');

      for (final d in devices) {
        expect(d.id, isNotEmpty);
        expect(d.name, isNotEmpty);
        // Typed model: enums, never raw ints/strings (0.1.0 contract).
        expect(CameraPosition.values, contains(d.position));
        expect(CameraLensType.values, contains(d.lensType));
        expect(HardwareLevel.values, contains(d.hardwareLevel));
        expect(
          d.sensorOrientation % 90,
          0,
          reason: '${d.id}: sensorOrientation must be a right angle',
        );
        expect(d.maxZoom, greaterThanOrEqualTo(d.minZoom));
        expect(d.maxPhotoWidth, greaterThan(0));
        expect(d.maxPhotoHeight, greaterThan(0));
        expect(
          d.formats,
          isNotEmpty,
          reason: '${d.id}: every device must report capture formats',
        );
        for (final f in d.formats) {
          expect(f.videoWidth, greaterThan(0));
          expect(f.videoHeight, greaterThan(0));
          expect(f.maxFps, greaterThanOrEqualTo(f.minFps));
          expect(AutoFocusSystem.values, contains(f.autoFocusSystem));
          expect(f.videoStabilizationModes, isNotEmpty);
        }
      }

      // Selectors (vision-camera getCameraDevice parity) on the real list.
      final back = devices.backCamera();
      final front = devices.frontCamera();
      expect(
        back ?? front,
        isNotNull,
        reason: 'selector must find at least one facing',
      );
      if (back != null) expect(back.position, CameraPosition.back);
      if (front != null) expect(front.position, CameraPosition.front);
      final wide = selectCameraDevice(
        devices,
        position: CameraPosition.back,
        physicalDevices: [PhysicalDeviceType.wideAngleCamera],
      );
      if (back != null) {
        expect(
          wide,
          isNotNull,
          reason:
              'wide-angle back selector must resolve when a back camera exists',
        );
      }

      // Constraint-based format negotiation against REAL formats.
      final dev = back ?? front!;
      final resolved = FormatResolver.resolve(dev, const [
        ResolutionConstraint(TargetResolution.closestTo(1920, 1080)),
        FpsConstraint(30),
      ]);
      expect(resolved, isNotNull);
      expect(resolved!.videoWidth * resolved.videoHeight, greaterThan(0));

      // Concurrent multi-cam combinations: may be empty, must never throw.
      final combos = CameraController.getConcurrentCameraIds();
      for (final combo in combos) {
        expect(combo, isNotEmpty);
      }
    },
  );

  testWidgets(
    '3. session state + declarative configure() without a reopen',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();

      final st = c.getSessionState();
      expect(st.running, isTrue);
      expect(st.width, greaterThan(0));
      expect(st.height, greaterThan(0));
      expect(st.fps, greaterThan(0));

      // Live-field configure() must be applied as ONE atomic native call and
      // must NOT reopen the session (same textureId).
      final beforeTid = c.textureId;
      final base = c.configuration;
      expect(
        base,
        isNotNull,
        reason: 'initialize() seeds the declarative configuration',
      );
      await c.configure(base!.copyWith(zoom: 2.0, exposure: 0.5));
      expect(
        c.textureId,
        beforeTid,
        reason: 'live-field configure must not tear down the session',
      );
      expect(c.configuration!.zoom, 2.0);
      expect(c.configuration!.exposure, 0.5);

      // Restore + read-back.
      await c.configure(base.copyWith(zoom: 1.0, exposure: 0.0));
      expect(c.textureId, beforeTid);
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(cameraStore.errorMessage.value, isNull);
      expect(c.getSessionState().running, isTrue);
    },
  );

  testWidgets(
    '4. every imperative live setter leaves a healthy session',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();
      final device = c.device;

      c.setZoom(2.0);
      expect(c.zoom, 2.0);
      c.setZoom(device.maxZoom + 100); // clamps, never throws
      expect(c.zoom, device.maxZoom);
      c.setZoom(1.0);

      c.setExposure(device.maxExposure / 2);
      expect(c.exposure, device.maxExposure / 2);
      c.setExposure(0.0);

      c.setFlash(FlashMode.auto);
      expect(c.flash, FlashMode.auto);
      c.setFlash(FlashMode.off);

      c.focus(0.5, 0.5);
      c.setAutoFocus(AutoFocusMode.locked);
      c.setAutoFocus(AutoFocusMode.continuous);

      c.setWhiteBalance(5600);
      c.setWhiteBalance(0); // back to auto

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
      c.setFilterShader(''); // exercise the FFI path with "no filter"

      // The setters are optimistic fire-and-forget: health means the session is
      // still streaming and no native error event surfaced.
      await pumpFor(tester, const Duration(seconds: 2));
      expect(cameraStore.status.value, CameraStatus.running);
      expect(
        cameraStore.errorMessage.value,
        isNull,
        reason: 'no live setter may surface a native error',
      );
      expect(c.getSessionState().running, isTrue);
    },
  );

  testWidgets(
    '5. torch + torch level (skipped without a torch unit)',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();
      if (!c.device.hasTorch) {
        markTestSkipped('active device has no torch');
        return;
      }

      c.setTorch(enabled: true);
      expect(c.torch, isTrue);
      await pumpFor(tester, const Duration(milliseconds: 500));
      c.setTorchLevel(0.5);
      expect(c.torch, isTrue);
      await pumpFor(tester, const Duration(milliseconds: 500));
      c.setTorch(enabled: false);
      expect(c.torch, isFalse);

      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(cameraStore.errorMessage.value, isNull);
      expect(cameraStore.status.value, CameraStatus.running);
    },
  );

  testWidgets(
    '6. preview pause/resume via setActive keeps the session',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();
      final tid = c.textureId;

      c.pausePreview();
      expect(c.isActive, isFalse);
      await pumpFor(tester, const Duration(seconds: 1));

      c.resumePreview();
      expect(c.isActive, isTrue);
      expect(c.textureId, tid, reason: 'pause/resume must not reopen');
      await pumpUntil(
        tester,
        () => c.getSessionState().running,
        timeout: const Duration(seconds: 10),
        reason: 'stream running again after resumePreview',
      );
      expect(cameraStore.errorMessage.value, isNull);
    },
  );

  testWidgets(
    '7. frameStream delivers only THIS session\'s frames with a sane '
    'zero-copy contract',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();

      final frames =
          <({int textureId, int w, int h, int size, int rowBytes})>[];
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
        tester,
        () => frames.length >= 5,
        timeout: const Duration(seconds: 15),
        reason: 'CPU frames delivered on frameStream',
      );
      await sub.cancel();
      c.setFrameProcessing(enabled: false);

      for (final f in frames) {
        expect(
          f.textureId,
          c.textureId,
          reason: 'frameStream must be filtered to its own session (§0 fix)',
        );
        expect(f.w, greaterThan(0));
        expect(f.h, greaterThan(0));
        expect(f.size, greaterThan(0));
        if (f.rowBytes > 0) {
          expect(
            f.size,
            f.rowBytes * f.h,
            reason: 'size must equal stride × height',
          );
        }
      }
    },
  );

  testWidgets(
    '8. frame-processor plugin registry runs on a worker isolate',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();

      FrameProcessorPlugins.register('meanLuma', createMeanLumaPlugin);
      expect(FrameProcessorPlugins.isRegistered('meanLuma'), isTrue);
      expect(
        () => FrameProcessorPlugins.init('no-such-plugin'),
        throwsArgumentError,
      );

      final runner = FrameProcessorPlugins.init('meanLuma', {'step': 64});
      final results = <Object?>[];
      final resultSub = runner.results.listen(results.add);
      final statsSeen = <FrameProcessStats>[];
      final statsSub = runner.stats.listen(statsSeen.add);

      await runner.start(c.frameStream);
      c.setFrameProcessing(enabled: true);

      await pumpUntil(
        tester,
        () => results.isNotEmpty && statsSeen.isNotEmpty,
        timeout: const Duration(seconds: 15),
        reason: 'plugin produced results + timing stats from live frames',
      );
      expect(results.first, isA<double>());
      expect((results.first as double), greaterThanOrEqualTo(0));
      expect(statsSeen.first.elapsedMicros, greaterThan(0));

      c.setFrameProcessing(enabled: false);
      await resultSub.cancel();
      await statsSub.cancel();
      await runner.dispose();
      await pumpFor(tester, const Duration(milliseconds: 300));
      expect(cameraStore.status.value, CameraStatus.running);
    },
  );

  testWidgets(
    '9. recording: options + pause/resume + typed result metadata + cancel',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();
      final dir = await getTemporaryDirectory();

      // Full control cycle with explicit options.
      final path =
          '${dir.path}/api_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await c.startRecording(
        path,
        options: const RecordingOptions(
          codec: 0, // h264
          fileType: 0, // mp4
          bitRate: 4_000_000,
        ),
      );
      expect(c.isRecording, isTrue);
      await pumpFor(tester, const Duration(seconds: 1));

      c.pauseRecording();
      expect(c.isRecordingPaused, isTrue);
      await pumpFor(tester, const Duration(milliseconds: 700));
      c.resumeRecording();
      expect(c.isRecordingPaused, isFalse);
      await pumpFor(tester, const Duration(seconds: 1));

      final rec = await c.stopRecording();
      expect(c.isRecording, isFalse);
      expect(rec.path, isNotEmpty);
      final f = File(rec.path);
      expect(f.existsSync(), isTrue);
      expect(rec.fileSize, greaterThan(0));
      expect(
        f.lengthSync(),
        rec.fileSize,
        reason: 'reported fileSize must match the file on disk',
      );
      expect(rec.durationMs, greaterThan(0));
      // Paused time must not count: ~2s recorded vs ~2.7s wall clock.
      expect(
        rec.durationMs,
        lessThan(2600),
        reason: 'paused span leaked into durationMs (${rec.durationMs}ms)',
      );
      // Typed metadata extensions.
      expect(rec.reason, RecordingFinishedReason.stopped);
      expect(rec.videoCodec, VideoCodec.h264);
      expect(rec.videoFileType, VideoFileType.mp4);
      f.deleteSync();

      // Cancel path: no file must survive.
      final cancelPath =
          '${dir.path}/api_cancel_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await c.startRecording(cancelPath);
      await pumpFor(tester, const Duration(milliseconds: 700));
      c.cancelRecording();
      expect(c.isRecording, isFalse);
      await pumpUntil(
        tester,
        () => !File(cancelPath).existsSync(),
        timeout: const Duration(seconds: 5),
        reason: 'cancelRecording deletes the partial file',
      );
      expect(cameraStore.errorMessage.value, isNull);
    },
  );

  testWidgets(
    '10. photo option variants: geotag, silent+speed, DNG',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();
      await pumpFor(tester, const Duration(seconds: 1)); // AE/AF settle

      // Geotagged, metadata on.
      final geo = await c.takePhotoWithOptions(
        const PhotoCaptureOptions(
          location: (latitude: 37.7749, longitude: -122.4194, altitude: 12.0),
        ),
      );
      expect(File(geo.path).existsSync(), isTrue);
      expect(geo.width, greaterThan(0));
      expect(geo.height, greaterThan(0));
      File(geo.path).deleteSync();

      // Silent + speed-prioritized + no metadata.
      final fast = await c.takePhotoWithOptions(
        const PhotoCaptureOptions(
          quality: QualityPrioritization.speed,
          enableShutterSound: false,
          skipMetadata: true,
        ),
      );
      expect(File(fast.path).existsSync(), isTrue);
      File(fast.path).deleteSync();

      // RAW/DNG only where the device reports support.
      if (c.device.supportsRawCapture) {
        final raw = await c.takePhotoWithOptions(
          const PhotoCaptureOptions(outputFormat: PhotoOutputFormat.dng),
        );
        expect(File(raw.path).existsSync(), isTrue);
        expect(raw.path.toLowerCase(), endsWith('.dng'));
        File(raw.path).deleteSync();
      }

      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(cameraStore.status.value, CameraStatus.running);
      expect(cameraStore.errorMessage.value, isNull);
    },
  );

  testWidgets(
    '11. native detector smoke: barcode on/off keeps frames flowing',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();

      // Turning a native ML detector on must not stall the stream (the
      // front-camera 4-stream starvation bug class), and detections — if any —
      // arrive as parsed maps on nativeDetections.
      final detections = <Map<String, dynamic>>[];
      final sub = c.nativeDetections.listen(detections.add);
      c.setNativeDetector('barcode');

      var framesSeen = 0;
      final frameSub = c.frameStream.listen((_) => framesSeen++);
      c.setFrameProcessing(enabled: true);
      await pumpUntil(
        tester,
        () => framesSeen > 5,
        timeout: const Duration(seconds: 15),
        reason: 'stream stays alive with the native detector attached',
      );

      c.setNativeDetector('');
      c.setFrameProcessing(enabled: false);
      await frameSub.cancel();
      await sub.cancel();
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(cameraStore.status.value, CameraStatus.running);
      expect(
        cameraStore.errorMessage.value,
        isNull,
        reason:
            'detector on/off must not surface an error '
            '(detections seen: ${detections.length})',
      );
    },
  );

  testWidgets(
    '12. typed errors + orientation manager + hot-plug observer lifecycles',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);

      // session/not-initialized: any control call before initialize() throws
      // the TYPED exception with its stable code (0.1.0 error contract). A
      // deliberately bogus openCamera is NOT exercised on-device: probing
      // nonexistent ids can wedge constrained HALs (OnePlus storms).
      final fresh = CameraController(device: ctrl().device);
      expect(
        () => fresh.setZoom(2.0),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            'session/not-initialized',
          ),
        ),
      );
      await fresh.dispose();

      // OrientationManager: start → (maybe) current orientation → drive →
      // dispose, without disturbing the session.
      final om = OrientationManager();
      await om.start();
      om.drive(ctrl(), OutputOrientationMode.device);
      await pumpFor(tester, const Duration(seconds: 1));
      final deg = om.currentOrientation;
      if (deg != null) expect(deg % 90, 0);
      om.drive(null);
      await om.dispose();

      // Hot-plug observer: enable/disable round-trip (no USB camera needed —
      // the contract is that the lifecycle itself is safe).
      final observer = CameraDevicesObserver();
      await observer.start();
      await pumpFor(tester, const Duration(milliseconds: 500));
      await observer.dispose();

      expect(cameraStore.status.value, CameraStatus.running);
      expect(cameraStore.errorMessage.value, isNull);
    },
  );
}
