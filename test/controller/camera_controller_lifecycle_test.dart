import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/native.dart'
    show CameraConfig, NitroCamera, ResolvedConfig;
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';
import 'controller_fixtures.dart';

/// Session lifecycle: `initialize`, the diff-driven `configure`, the
/// freeze-frame `closeSession`/`dispose` pair, and the static helpers.
void main() {
  late FakeNitroCamera fake;

  setUp(() => fake = FakeNitroCamera());
  tearDown(() => fake.close());

  CameraController controllerFor({
    CameraDeviceFormat? format,
    bool audio = false,
    CameraDeviceInfo? device,
  }) => CameraController(
    device: device ?? testDevice(),
    format: format,
    audio: audio,
    native: fake,
  );

  group('initialize', () {
    test('with no format targets 1080p30 and publishes the texture', () async {
      final c = controllerFor();
      var notifications = 0;
      c.addListener(() => notifications++);

      await c.initialize();

      expect(fake.argsOf('openCamera'), ['cam0', 1920, 1080, 30, 0]);
      expect(c.textureId, 7);
      expect(c.isInitialized, isTrue);
      expect(c.isActive, isTrue);
      expect(c.sensorOrientation, 270, reason: 'copied from the device');
      expect(notifications, 1);
      expect(c.configuration!.deviceId, 'cam0');
      expect(c.configuration!.format, isNull);
      expect(c.configuration!.fps, 30);
      expect(c.configuration!.enableAudio, isFalse);
      expect(c.configuration!.isActive, isTrue);
      expect(
        c.resolvedConfig,
        isNull,
        reason: 'nothing to resolve without a format',
      );
    });

    test('explicit width/height/fps override the format', () async {
      final c = controllerFor(format: testFormat(), audio: true);

      await c.initialize(width: 640, height: 480, fps: 15);

      expect(fake.argsOf('openCamera'), ['cam0', 640, 480, 15, 1]);
      expect(c.configuration!.fps, 15);
    });

    test('derives size and fps from the format when given', () async {
      final c = controllerFor(
        format: testFormat(width: 1280, height: 720, maxFps: 60),
      );

      await c.initialize();

      expect(fake.argsOf('openCamera'), ['cam0', 1280, 720, 60, 0]);
      expect(c.configuration!.fps, 60);
      expect(c.resolvedConfig!.selectedFps, 60);
      expect(c.resolvedConfig!.videoWidth, 1280);
      expect(c.resolvedConfig!.videoHeight, 720);
      expect(c.resolvedConfig!.photoWidth, 2560);
      expect(c.resolvedConfig!.photoHeight, 1440);
      expect(c.resolvedConfig!.videoHdrEnabled, isFalse);
      expect(c.resolvedConfig!.pixelFormat, PixelFormat.bgra);
      expect(c.resolvedConfig!.autoFocusSystem, AutoFocusSystem.none);
    });

    test('a 0 texture id surfaces device/open-failed', () async {
      fake.openCameraResult = 0;
      final c = controllerFor();

      await expectLater(
        c.initialize(),
        throwsA(
          isA<DeviceException>()
              .having((e) => e.code, 'code', 'device/open-failed')
              .having((e) => e.message, 'message', contains('cam0')),
        ),
      );
      expect(c.isInitialized, isFalse);
      expect(c.textureId, isNull);
    });

    test('the session-state read-back replaces the requested size', () async {
      fake.sessionStateJson = sessionStateJson(width: 1440, height: 1080);
      final c = controllerFor();

      await c.initialize(width: 1920, height: 1080);

      expect(fake.argsOf('getSessionStateJson'), [7]);
      expect(c.width, 1440);
      expect(c.height, 1080);
    });

    test('a zero-sized read-back leaves the requested size intact', () async {
      fake.sessionStateJson = sessionStateJson(
        running: false,
        width: 0,
        height: 0,
      );
      final c = controllerFor();

      await c.initialize(width: 800, height: 600);

      expect(c.width, 800);
      expect(c.height, 600);
    });

    test('a throwing read-back never aborts the open', () async {
      fake.failWith('getSessionStateJson', StateError('bridge hiccup'));
      final c = controllerFor();

      await c.initialize(width: 800, height: 600);

      expect(c.isInitialized, isTrue, reason: 'defensive catch');
      expect(c.width, 800);
      expect(c.height, 600);
    });
  });

  group('configure', () {
    test('an empty diff touches native at all', () async {
      final c = controllerFor(format: testFormat());
      await c.initialize();
      fake.clear();

      await c.configure(c.configuration!);

      expect(fake.calls, isEmpty);
    });

    test('a live-only diff configures without reopening', () async {
      final c = controllerFor(format: testFormat());
      await c.initialize();
      fake.clear();
      var notifications = 0;
      c.addListener(() => notifications++);

      await c.configure(c.configuration!.copyWith(zoom: 3.0, exposure: -1.5));

      expect(fake.callNames, ['configure']);
      expect(c.textureId, 7, reason: 'no reopen');
      final cfg = fake.argsOf('configure')![1] as CameraConfig;
      expect(fake.argsOf('configure')![0], 7);
      expect(cfg.zoom, 3.0);
      expect(cfg.exposure, -1.5);
      expect(c.configuration!.zoom, 3.0);
      expect(notifications, 1);
    });

    test('isActive false is applied live and mirrored on the controller',
        () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.configure(c.configuration!.copyWith(isActive: false));

      expect(fake.callNames, ['configure']);
      expect((fake.argsOf('configure')![1] as CameraConfig).active, 0);
      expect(c.isActive, isFalse);
    });

    test('an fps change closes and reopens, changing the texture id', () async {
      final c = controllerFor(format: testFormat(width: 1280, height: 720));
      await c.initialize();
      fake.clear();
      fake.openCameraResult = 11;

      await c.configure(c.configuration!.copyWith(fps: 24));

      expect(fake.callNames, ['closeCamera', 'openCamera', 'configure']);
      expect(fake.argsOf('closeCamera'), [7]);
      expect(fake.argsOf('openCamera'), ['cam0', 1280, 720, 24, 0]);
      expect(c.textureId, 11);
      expect(c.width, 1280);
      expect(c.height, 720);
      expect(c.isActive, isTrue);
      expect(fake.argsOf('configure')![0], 11, reason: 'the new session');
    });

    test('a reopen without a format keeps the current size and falls back to '
        'the constructor device id', () async {
      fake.sessionStateJson = sessionStateJson(width: 1440, height: 1080);
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.configure(const CameraConfiguration(fps: 48));

      expect(fake.argsOf('openCamera'), ['cam0', 1440, 1080, 48, 0]);
      expect(c.width, 1440);
      expect(c.height, 1080);
    });

    test('a device change reopens against the new id with audio', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.configure(
        const CameraConfiguration(deviceId: 'cam1', fps: 30, enableAudio: true),
      );

      expect(fake.argsOf('openCamera')![0], 'cam1');
      expect(fake.argsOf('openCamera')![4], 1);
    });

    test('a failed reopen throws and leaves the controller uninitialised',
        () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();
      fake.openCameraResult = 0;

      await expectLater(
        c.configure(const CameraConfiguration(deviceId: 'cam9', fps: 30)),
        throwsA(
          isA<DeviceException>()
              .having((e) => e.code, 'code', 'device/open-failed')
              .having((e) => e.message, 'message', contains('cam9')),
        ),
      );
      expect(c.textureId, isNull);
      expect(c.isInitialized, isFalse);
      expect(fake.called('configure'), isFalse);
    });

    test('a filter diff pushes the shader as a separate call', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.configure(c.configuration!.copyWith(filterShader: 'void main(){}'));

      expect(fake.callNames, ['configure', 'setFilterShader']);
      expect(fake.argsOf('setFilterShader'), [7, 'void main(){}']);
    });

    test('no filter diff means no shader call', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.configure(c.configuration!.copyWith(torch: true));

      expect(fake.callNames, ['configure']);
    });

    test('the native read-back wins over the Dart-side guesses', () async {
      final c = controllerFor(
        format: testFormat(width: 1280, height: 720, supportsVideoHdr: true),
      );
      await c.initialize();
      fake.resolvedConfig = const ResolvedConfig(
        width: 3840,
        height: 2160,
        fps: 24,
        pixelFormat: 1,
        videoHdrEnabled: 1,
        autoFocusSystem: 2,
        active: 1,
      );

      await c.configure(
        c.configuration!.copyWith(
          zoom: 2.0,
          videoHdr: false,
          pixelFormat: PixelFormat.yuv420,
        ),
      );

      final r = c.resolvedConfig!;
      expect(r.videoWidth, 3840, reason: 'native, not the format 1280');
      expect(r.videoHeight, 2160);
      expect(r.selectedFps, 24, reason: 'native, not the requested 60');
      expect(r.pixelFormat, PixelFormat.bgra, reason: 'native 1, not yuv420');
      expect(r.videoHdrEnabled, isTrue, reason: 'native 1, not the false ask');
      expect(r.autoFocusSystem, AutoFocusSystem.phaseDetection);
      expect(r.photoWidth, 2560, reason: 'photo size stays format-derived');
    });

    test('a null resolution keeps the previous resolvedConfig', () async {
      final c = controllerFor(format: testFormat());
      await c.initialize();
      final before = c.resolvedConfig;
      expect(before, isNotNull);

      // A configuration without a format resolves to null -> keep the old one.
      await c.configure(const CameraConfiguration(deviceId: 'cam0', fps: 30));

      expect(c.resolvedConfig, same(before));
    });

    test('maps every autoFocusSystem wire value', () async {
      Future<AutoFocusSystem> resolveWith(int wire) async {
        final f = FakeNitroCamera();
        addTearDown(f.close);
        final c = CameraController(
          device: testDevice(),
          format: testFormat(),
          native: f,
        );
        await c.initialize();
        f.resolvedConfig = ResolvedConfig(
          width: 1280,
          height: 720,
          fps: 60,
          pixelFormat: 0,
          videoHdrEnabled: 0,
          autoFocusSystem: wire,
          active: 1,
        );
        await c.configure(c.configuration!.copyWith(zoom: 2.0));
        return c.resolvedConfig!.autoFocusSystem;
      }

      expect(await resolveWith(0), AutoFocusSystem.none);
      expect(await resolveWith(1), AutoFocusSystem.contrastDetection);
      expect(await resolveWith(2), AutoFocusSystem.phaseDetection);
      expect(
        await resolveWith(99),
        AutoFocusSystem.none,
        reason: 'unknown wire value degrades to none',
      );
    });

    test('rejects a configure before initialize', () async {
      final c = controllerFor();
      await expectLater(
        c.configure(const CameraConfiguration(deviceId: 'cam0')),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            'session/not-initialized',
          ),
        ),
      );
    });
  });

  group('initializeWithTexture', () {
    test('adopts an already-open session and seeds the configuration', () {
      final c = controllerFor();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.initializeWithTexture(42, 1600, 1200, 90, fps: 24);

      expect(c.textureId, 42);
      expect(c.isInitialized, isTrue);
      expect(c.width, 1600);
      expect(c.height, 1200);
      expect(c.sensorOrientation, 90);
      expect(c.isActive, isTrue);
      expect(c.configuration!.deviceId, 'cam0');
      expect(c.configuration!.fps, 24);
      expect(c.configuration!.isActive, isTrue);
      expect(c.resolvedConfig, isNull, reason: 'no format was negotiated');
      expect(notifications, 1);
      expect(fake.calls, isEmpty, reason: 'the session is already open');
    });

    test('defaults fps to 30', () {
      final c = controllerFor();
      c.initializeWithTexture(1, 640, 480, 0);
      expect(c.configuration!.fps, 30);
    });

    test('the seeded configuration lets a later configure stay live', () async {
      final c = controllerFor();
      c.initializeWithTexture(42, 1600, 1200, 90);

      await c.configure(c.configuration!.copyWith(zoom: 2.0));

      expect(fake.callNames, ['configure'], reason: 'no spurious reopen');
      expect(c.textureId, 42);
    });
  });

  group('closeSession / dispose', () {
    test('closeSession closes the hardware but keeps the texture', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.closeSession();

      expect(fake.callNames, ['closeCamera']);
      expect(fake.argsOf('closeCamera'), [7]);
      expect(c.textureId, 7, reason: 'the freeze-frame stays mounted');
      expect(c.isInitialized, isTrue);
    });

    test('closeSession is idempotent', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.closeSession();
      await c.closeSession();

      expect(fake.callNames, ['closeCamera']);
    });

    test('dispose closes once and clears the texture', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.dispose();

      expect(fake.callNames, ['closeCamera']);
      expect(c.textureId, isNull);
      expect(c.isInitialized, isFalse);
    });

    test('dispose is idempotent', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.dispose();
      await c.dispose();

      expect(fake.callNames, ['closeCamera']);
    });

    test('closeSession then dispose closes exactly once', () async {
      final c = controllerFor();
      await c.initialize();
      fake.clear();

      await c.closeSession();
      await c.dispose();

      expect(fake.callNames, ['closeCamera']);
      expect(c.textureId, isNull);
    });

    test('closeSession after dispose is a no-op', () async {
      final c = controllerFor();
      await c.initialize();
      await c.dispose();
      fake.clear();

      await c.closeSession();

      expect(fake.calls, isEmpty);
    });

    test('dispose without a session never calls closeCamera', () async {
      final c = controllerFor();
      await c.dispose();
      expect(fake.calls, isEmpty);
    });

    test('every control throws session/not-initialized after dispose',
        () async {
      final c = controllerFor();
      await c.initialize();
      await c.dispose();

      final notInitialized = throwsA(
        isA<SessionException>().having(
          (e) => e.code,
          'code',
          'session/not-initialized',
        ),
      );
      expect(() => c.setZoom(2.0), notInitialized);
      expect(() => c.setActive(false), notInitialized);
      expect(() => c.getSessionState(), notInitialized);
      expect(c.takePhoto(), notInitialized);
    });
  });

  group('getSessionState', () {
    test('parses the live native snapshot', () async {
      fake.sessionStateJson = sessionStateJson(
        width: 1280,
        height: 720,
        fps: 24,
        pixelFormat: 1,
      );
      final c = controllerFor();
      await c.initialize();

      final st = c.getSessionState();

      expect(st.running, isTrue);
      expect(st.width, 1280);
      expect(st.height, 720);
      expect(st.fps, 24);
      expect(st.pixelFormat, PixelFormat.bgra);
    });
  });

  group('statics', () {
    test('getAvailableCameraDevices parses the native payload', () async {
      fake.availableCameraDevicesJson = '''
[{"id":"back","name":"Back","position":1,"lensType":1,"sensorOrientation":90,
  "minZoom":1.0,"maxZoom":10.0,"neutralZoom":1.0,"hasFlash":true,"hasTorch":true,
  "maxPhotoWidth":4032,"maxPhotoHeight":3024,"hardwareLevel":"full",
  "formats":[{"photoWidth":4032,"photoHeight":3024,"videoWidth":1920,
              "videoHeight":1080,"minFps":15,"maxFps":30}]}]''';

      final devices = await CameraController.getAvailableCameraDevices(
        native: fake,
      );

      expect(fake.called('getAvailableCameraDevicesJson'), isTrue);
      expect(devices, hasLength(1));
      expect(devices.single.id, 'back');
      expect(devices.single.isBackCamera, isTrue);
      expect(devices.single.maxZoom, 10.0);
      expect(devices.single.formats.single.videoWidth, 1920);
    });

    test('getAvailableCameraDevices rejects a malformed payload', () async {
      fake.availableCameraDevicesJson = '{"not":"a list"}';

      await expectLater(
        CameraController.getAvailableCameraDevices(native: fake),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            'session/malformed-payload',
          ),
        ),
      );
    });

    test('requestCameraPermission maps the native index', () async {
      fake.requestCameraPermissionResult = 1;
      expect(
        await CameraController.requestCameraPermission(native: fake),
        PermissionStatus.granted,
      );
      expect(fake.called('requestCameraPermission'), isTrue);

      fake.requestCameraPermissionResult = 3;
      expect(
        await CameraController.requestCameraPermission(native: fake),
        PermissionStatus.restricted,
      );
    });

    test('requestMicrophonePermission maps the native index', () async {
      fake.requestMicrophonePermissionResult = 0;
      expect(
        await CameraController.requestMicrophonePermission(native: fake),
        PermissionStatus.notDetermined,
      );
      expect(fake.called('requestMicrophonePermission'), isTrue);
    });

    test('an out-of-range permission index degrades to denied', () async {
      fake.requestCameraPermissionResult = 99;
      expect(
        await CameraController.requestCameraPermission(native: fake),
        PermissionStatus.denied,
      );

      fake.requestMicrophonePermissionResult = -1;
      expect(
        await CameraController.requestMicrophonePermission(native: fake),
        PermissionStatus.denied,
      );
    });

    test('getConcurrentCameraIds parses combinations', () {
      fake.concurrentCameraIdsJson = '[["0","1"],["0","2"]]';

      final combos = CameraController.getConcurrentCameraIds(native: fake);

      expect(fake.called('getConcurrentCameraIdsJson'), isTrue);
      expect(combos, [
        ['0', '1'],
        ['0', '2'],
      ]);
    });

    test('an unsupported device reports a well-formed empty list', () {
      fake.concurrentCameraIdsJson = '[]';
      expect(CameraController.getConcurrentCameraIds(native: fake), isEmpty);
    });

    test('junk concurrent-id payloads throw instead of looking unsupported',
        () {
      fake.concurrentCameraIdsJson = 'not-json';
      expect(
        () => CameraController.getConcurrentCameraIds(native: fake),
        throwsA(
          isA<SessionException>()
              .having((e) => e.code, 'code', 'session/malformed-payload')
              .having(
                (e) => e.message,
                'message',
                contains('concurrent-camera-IDs'),
              ),
        ),
      );

      fake.concurrentCameraIdsJson = '{"combos":[]}';
      expect(
        () => CameraController.getConcurrentCameraIds(native: fake),
        throwsA(isA<SessionException>()),
      );
    });

  });

  group('the default bridge', () {
    // Every `native:` seam falls back to the process-wide
    // `NitroCamera.instance`, which loads the FFI library. A unit-test host has
    // no such library, so each default path must fail loudly instead of
    // silently no-op'ing against a half-built bridge.
    test('is unavailable without a loaded native library', () {
      expect(() => NitroCamera.instance, throwsA(anything));
    });

    test('the constructor resolves it when no fake is injected', () {
      expect(() => CameraController(device: testDevice()), throwsA(anything));
    });

    test('requestCameraPermission resolves it', () {
      expect(CameraController.requestCameraPermission(), throwsA(anything));
    });

    test('requestMicrophonePermission resolves it', () {
      expect(CameraController.requestMicrophonePermission(), throwsA(anything));
    });

    test('getAvailableCameraDevices resolves it', () {
      expect(CameraController.getAvailableCameraDevices(), throwsA(anything));
    });

    test('getConcurrentCameraIds resolves it', () {
      expect(() => CameraController.getConcurrentCameraIds(), throwsA(anything));
    });

    test('allEvents resolves it', () {
      expect(() => CameraController.allEvents, throwsA(anything));
    });
  });
}
