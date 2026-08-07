import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/native.dart' show PhotoOptions;
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';
import 'controller_fixtures.dart';

/// Imperative controls: the exact native call each setter makes, the value
/// clamping, and the [CameraConfiguration] each one patches so a later
/// `configure` diffs correctly.
void main() {
  late FakeNitroCamera fake;
  late CameraController c;

  setUp(() async {
    fake = FakeNitroCamera();
    c = CameraController(
      device: testDevice(minZoom: 1.0, maxZoom: 8.0),
      native: fake,
    );
    await c.initialize();
    fake.clear();
  });

  tearDown(() async {
    await c.dispose();
    await fake.close();
  });

  group('preview activity', () {
    test('setActive(false) stops the preview and notifies', () {
      var n = 0;
      c.addListener(() => n++);

      c.setActive(false);

      expect(fake.callNames, ['stopPreview']);
      expect(fake.argsOf('stopPreview'), [7]);
      expect(c.isActive, isFalse);
      expect(n, 1);
    });

    test('setActive with the current value is a no-op', () {
      var n = 0;
      c.addListener(() => n++);

      c.setActive(true);

      expect(fake.calls, isEmpty);
      expect(c.isActive, isTrue);
      expect(n, 0);
    });

    test('setActive(true) after a stop restarts the preview', () {
      c.setActive(false);
      fake.clear();

      c.setActive(true);

      expect(fake.callNames, ['startPreview']);
      expect(fake.argsOf('startPreview'), [7]);
      expect(c.isActive, isTrue);
    });

    test('pausePreview / resumePreview delegate to setActive', () {
      c.pausePreview();
      expect(fake.callNames, ['stopPreview']);
      expect(c.isActive, isFalse);

      c.pausePreview();
      expect(fake.callNames, ['stopPreview'], reason: 'already paused');

      c.resumePreview();
      expect(fake.callNames, ['stopPreview', 'startPreview']);
      expect(c.isActive, isTrue);
    });
  });

  group('zoom', () {
    test('passes an in-range value straight through and patches the config',
        () {
      var n = 0;
      c.addListener(() => n++);

      c.setZoom(2.5);

      expect(fake.argsOf('setZoom'), [7, 2.5]);
      expect(c.zoom, 2.5);
      expect(c.configuration!.zoom, 2.5);
      expect(n, 1);
    });

    test('clamps above device.maxZoom', () {
      c.setZoom(1000.0);
      expect(fake.argsOf('setZoom'), [7, 8.0]);
      expect(c.zoom, 8.0);
      expect(c.configuration!.zoom, 8.0);
    });

    test('clamps below device.minZoom', () {
      c.setZoom(0.01);
      expect(fake.argsOf('setZoom'), [7, 1.0]);
      expect(c.zoom, 1.0);
    });
  });

  group('focus & exposure', () {
    test('focus forwards the normalised point without touching state', () {
      c.focus(0.25, 0.75);
      expect(fake.argsOf('setFocusPoint'), [7, 0.25, 0.75]);
      expect(c.configuration!.zoom, 1.0, reason: 'focus patches nothing');
    });

    test('setAutoFocus sends the mode index and patches the config', () {
      c.setAutoFocus(AutoFocusMode.locked);
      expect(fake.argsOf('setAutoFocus'), [7, 2]);
      expect(c.configuration!.autoFocus, AutoFocusMode.locked);

      c.setAutoFocus(AutoFocusMode.off);
      expect(fake.argsOf('setAutoFocus'), [7, 0]);
      expect(c.configuration!.autoFocus, AutoFocusMode.off);
    });

    test('setExposure stores the bias and notifies', () {
      var n = 0;
      c.addListener(() => n++);

      c.setExposure(-1.5);

      expect(fake.argsOf('setExposure'), [7, -1.5]);
      expect(c.exposure, -1.5);
      expect(c.configuration!.exposure, -1.5);
      expect(n, 1);
    });

    test('lockExposure / lockFocus / lockWhiteBalance send 0 or 1', () {
      c.lockExposure(locked: true);
      c.lockFocus(locked: true);
      c.lockWhiteBalance(locked: true);
      expect(fake.argsOf('lockExposure'), [7, 1]);
      expect(fake.argsOf('lockFocus'), [7, 1]);
      expect(fake.argsOf('lockWhiteBalance'), [7, 1]);

      c.lockExposure(locked: false);
      c.lockFocus(locked: false);
      c.lockWhiteBalance(locked: false);
      expect(fake.argsOf('lockExposure'), [7, 0]);
      expect(fake.argsOf('lockFocus'), [7, 0]);
      expect(fake.argsOf('lockWhiteBalance'), [7, 0]);
    });
  });

  group('flash & torch', () {
    test('setFlash sends the mode index, stores it and notifies', () {
      var n = 0;
      c.addListener(() => n++);

      c.setFlash(FlashMode.auto);

      expect(fake.argsOf('setFlash'), [7, 2]);
      expect(c.flash, FlashMode.auto);
      expect(c.configuration!.flash, FlashMode.auto);
      expect(n, 1);
    });

    test('setTorch toggles both directions', () {
      c.setTorch(enabled: true);
      expect(fake.argsOf('setTorch'), [7, 1]);
      expect(c.torch, isTrue);
      expect(c.configuration!.torch, isTrue);

      c.setTorch(enabled: false);
      expect(fake.argsOf('setTorch'), [7, 0]);
      expect(c.torch, isFalse);
      expect(c.configuration!.torch, isFalse);
    });

    test('setTorchLevel clamps to 0..1 and implies torch on above 0', () {
      c.setTorchLevel(0.5);
      expect(fake.argsOf('setTorchLevel'), [7, 0.5]);
      expect(c.torch, isTrue);
      expect(c.configuration!.torch, isTrue);

      c.setTorchLevel(9.0);
      expect(fake.argsOf('setTorchLevel'), [7, 1.0]);
      expect(c.torch, isTrue);

      c.setTorchLevel(-3.0);
      expect(fake.argsOf('setTorchLevel'), [7, 0.0], reason: 'clamped to 0');
      expect(c.torch, isFalse, reason: 'level 0 means torch off');
      expect(c.configuration!.torch, isFalse);

      c.setTorchLevel(0.0);
      expect(fake.argsOf('setTorchLevel'), [7, 0.0]);
      expect(c.torch, isFalse);
    });
  });

  group('image pipeline settings', () {
    test('setWhiteBalance sends kelvin and patches the config', () {
      c.setWhiteBalance(5600);
      expect(fake.argsOf('setWhiteBalance'), [7, 5600]);
      expect(c.configuration!.whiteBalanceKelvin, 5600);

      c.setWhiteBalance(0);
      expect(fake.argsOf('setWhiteBalance'), [7, 0], reason: 'back to auto');
      expect(c.configuration!.whiteBalanceKelvin, 0);
    });

    test('setHdr sends 0/1 and patches the config', () {
      c.setHdr(enabled: true);
      expect(fake.argsOf('setHdr'), [7, 1]);
      expect(c.configuration!.videoHdr, isTrue);

      c.setHdr(enabled: false);
      expect(fake.argsOf('setHdr'), [7, 0]);
      expect(c.configuration!.videoHdr, isFalse);
    });

    test('setPixelFormat maps to the frame-format index', () {
      c.setPixelFormat(PixelFormat.yuv420);
      expect(fake.argsOf('setFrameFormat'), [7, 0]);
      expect(c.configuration!.pixelFormat, PixelFormat.yuv420);

      c.setPixelFormat(PixelFormat.bgra);
      expect(fake.argsOf('setFrameFormat'), [7, 1]);
      expect(c.configuration!.pixelFormat, PixelFormat.bgra);
    });

    test('setSamplingRate forwards the stride', () {
      c.setSamplingRate(4);
      expect(fake.argsOf('setSamplingRate'), [7, 4]);
      expect(c.configuration!.samplingRate, 4);
    });

    test('setVideoStabilization sends the mode index', () {
      c.setVideoStabilization(VideoStabilizationMode.cinematic);
      expect(fake.argsOf('setVideoStabilization'), [7, 2]);
      expect(
        c.configuration!.videoStabilization,
        VideoStabilizationMode.cinematic,
      );

      c.setVideoStabilization(VideoStabilizationMode.auto);
      expect(fake.argsOf('setVideoStabilization'), [7, 4]);
    });

    test('setLowLightBoost sends 0/1', () {
      c.setLowLightBoost(enabled: true);
      expect(fake.argsOf('setLowLightBoost'), [7, 1]);
      expect(c.configuration!.lowLightBoost, isTrue);

      c.setLowLightBoost(enabled: false);
      expect(fake.argsOf('setLowLightBoost'), [7, 0]);
      expect(c.configuration!.lowLightBoost, isFalse);
    });

    test('setTargetOrientation forwards degrees verbatim', () {
      c.setTargetOrientation(180);
      expect(fake.argsOf('setTargetOrientation'), [7, 180]);
    });

    test('setDistortionCorrection sends 0/1', () {
      c.setDistortionCorrection(enabled: true);
      expect(fake.argsOf('setDistortionCorrection'), [7, 1]);

      c.setDistortionCorrection(enabled: false);
      expect(fake.argsOf('setDistortionCorrection'), [7, 0]);
    });

    test('setFilterShader forwards the source and patches the config', () {
      c.setFilterShader('void main() { gl_FragColor = vec4(1.0); }');
      expect(fake.argsOf('setFilterShader'), [
        7,
        'void main() { gl_FragColor = vec4(1.0); }',
      ]);
      expect(
        c.configuration!.filterShader,
        'void main() { gl_FragColor = vec4(1.0); }',
      );
    });
  });

  group('frame processing', () {
    test('setFrameProcessing toggles delivery and patches the config', () {
      c.setFrameProcessing(enabled: true);
      expect(fake.argsOf('enableFrameProcessing'), [7, 1]);
      expect(c.configuration!.enableFrameProcessing, isTrue);

      c.setFrameProcessing(enabled: false);
      expect(fake.argsOf('enableFrameProcessing'), [7, 0]);
      expect(c.configuration!.enableFrameProcessing, isFalse);
    });

    test('enableFrameProcessing / disableFrameProcessing are shorthands', () {
      c.enableFrameProcessing();
      expect(fake.argsOf('enableFrameProcessing'), [7, 1]);
      expect(c.configuration!.enableFrameProcessing, isTrue);

      c.disableFrameProcessing();
      expect(fake.argsOf('enableFrameProcessing'), [7, 0]);
      expect(c.configuration!.enableFrameProcessing, isFalse);
    });
  });

  group('native detectors', () {
    test('setNativeDetector forwards the wire string', () {
      c.setNativeDetector('barcode');
      expect(fake.argsOf('setNativeDetector'), [7, 'barcode']);
    });

    test('startDetector uses the typed detector wire value', () {
      c.startDetector(NativeDetector.face);
      expect(fake.argsOf('setNativeDetector'), [7, 'face']);

      c.startDetector(NativeDetector.barcode);
      expect(fake.argsOf('setNativeDetector'), [7, 'barcode']);
    });

    test('stopDetector clears the detector', () {
      c.startDetector(NativeDetector.barcode);
      c.stopDetector();
      expect(fake.argsOf('setNativeDetector'), [7, '']);
    });
  });

  group('photo capture', () {
    test('takePhoto returns the native result', () async {
      final photo = await c.takePhoto();

      expect(fake.argsOf('takePhoto'), [7]);
      expect(photo.path, '/tmp/fake.jpg');
      expect(photo.width, 1920);
      expect(photo.height, 1080);
    });

    test('takePhotoWithOptions projects the typed options onto the struct',
        () async {
      final photo = await c.takePhotoWithOptions(
        const PhotoCaptureOptions(
          flash: FlashMode.on,
          quality: QualityPrioritization.quality,
          enableShutterSound: false,
          skipMetadata: true,
          enableAutoRedEyeReduction: false,
          location: (latitude: 12.5, longitude: -3.25, altitude: 7.0),
          outputFormat: PhotoOutputFormat.dng,
        ),
      );

      expect(photo.path, '/tmp/fake.jpg');
      final args = fake.argsOf('takePhotoWithOptions')!;
      expect(args[0], 7);
      final o = args[1] as PhotoOptions;
      expect(o.flash, 1);
      expect(o.qualityPrioritization, 2);
      expect(o.enableShutterSound, 0);
      expect(o.skipMetadata, 1);
      expect(o.enableAutoRedEyeReduction, 0);
      expect(o.latitude, 12.5);
      expect(o.longitude, -3.25);
      expect(o.altitude, 7.0);
      expect(o.hasLocation, 1);
      expect(o.outputFormat, 1);
    });

    test('takeSnapshot returns the native result', () async {
      final photo = await c.takeSnapshot();

      expect(fake.argsOf('takeSnapshot'), [7]);
      expect(photo.path, '/tmp/fake.jpg');
    });
  });

  group('uninitialised controller', () {
    test('every control rejects a call before initialize', () {
      final fresh = CameraController(device: testDevice(), native: fake);
      addTearDown(fresh.dispose);
      final notInitialized = throwsA(
        isA<SessionException>().having(
          (e) => e.code,
          'code',
          'session/not-initialized',
        ),
      );

      expect(() => fresh.setZoom(2.0), notInitialized);
      expect(() => fresh.focus(0.5, 0.5), notInitialized);
      expect(() => fresh.setAutoFocus(AutoFocusMode.off), notInitialized);
      expect(() => fresh.setExposure(1.0), notInitialized);
      expect(() => fresh.setFlash(FlashMode.on), notInitialized);
      expect(() => fresh.setTorch(enabled: true), notInitialized);
      expect(() => fresh.setWhiteBalance(5000), notInitialized);
      expect(() => fresh.setHdr(enabled: true), notInitialized);
      expect(() => fresh.setPixelFormat(PixelFormat.bgra), notInitialized);
      expect(() => fresh.setSamplingRate(2), notInitialized);
      expect(
        () => fresh.setVideoStabilization(VideoStabilizationMode.standard),
        notInitialized,
      );
      expect(() => fresh.setLowLightBoost(enabled: true), notInitialized);
      expect(() => fresh.setTorchLevel(0.5), notInitialized);
      expect(() => fresh.lockExposure(locked: true), notInitialized);
      expect(() => fresh.lockFocus(locked: true), notInitialized);
      expect(() => fresh.lockWhiteBalance(locked: true), notInitialized);
      expect(() => fresh.setTargetOrientation(90), notInitialized);
      expect(
        () => fresh.setDistortionCorrection(enabled: true),
        notInitialized,
      );
      expect(() => fresh.setFilterShader('x'), notInitialized);
      expect(() => fresh.setFrameProcessing(enabled: true), notInitialized);
      expect(() => fresh.enableFrameProcessing(), notInitialized);
      expect(() => fresh.disableFrameProcessing(), notInitialized);
      expect(() => fresh.setNativeDetector('barcode'), notInitialized);
      expect(() => fresh.startDetector(NativeDetector.face), notInitialized);
      expect(() => fresh.stopDetector(), notInitialized);
      expect(() => fresh.setActive(false), notInitialized);
      expect(() => fresh.pausePreview(), notInitialized);
      expect(() => fresh.resumePreview(), notInitialized);
      expect(() => fresh.getSessionState(), notInitialized);
      expect(fresh.takePhoto(), notInitialized);
      expect(
        fresh.takePhotoWithOptions(const PhotoCaptureOptions()),
        notInitialized,
      );
      expect(fresh.takeSnapshot(), notInitialized);
      expect(fake.calls, isEmpty, reason: 'nothing reached native');
    });
  });
}
