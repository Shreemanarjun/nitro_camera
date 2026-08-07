import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';

/// Wire indices of the event types this file drives. Hard-coded on purpose:
/// the manager filters on them, so a silent reordering of `CameraEventType`
/// must fail here rather than at runtime on a device.
const _kStarted = 0;
const _kDeviceConnected = 9;
const _kDeviceDisconnected = 10;
const _kOrientationChanged = 11;

const _device = CameraDeviceInfo(
  id: 'back-0',
  name: 'Back Camera',
  position: CameraPosition.back,
  lensType: CameraLensType.wideAngle,
  sensorOrientation: 90,
  minZoom: 1,
  maxZoom: 8,
  neutralZoom: 1,
  hasFlash: true,
  hasTorch: true,
  maxPhotoWidth: 4032,
  maxPhotoHeight: 3024,
);

void main() {
  late FakeNitroCamera fake;

  setUp(() {
    fake = FakeNitroCamera();
    // Index sanity: the manager's filtering is index-based.
    expect(CameraEventType.values[_kOrientationChanged], CameraEventType.orientationChanged);
    expect(CameraEventType.values[_kDeviceConnected], CameraEventType.deviceConnected);
    expect(CameraEventType.values[_kDeviceDisconnected], CameraEventType.deviceDisconnected);
    expect(CameraEventType.values[_kStarted], CameraEventType.started);
  });

  tearDown(() => fake.close());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<CameraController> openController() async {
    final c = CameraController(device: _device, native: fake);
    await c.initialize();
    fake.clear();
    return c;
  }

  group('OrientationManager.start', () {
    test('enables the native sensor exactly once, however often it is started', () async {
      final m = OrientationManager(native: fake);

      await m.start();
      await m.start();
      await m.start();

      expect(
        fake.calls.where((c) => c.name == 'enableOrientationEvents').length,
        1,
      );
      expect(fake.argsOf('enableOrientationEvents'), [1]);

      await m.dispose();
    });

    test('publishes orientation degrees and remembers the latest', () async {
      final m = OrientationManager(native: fake);
      expect(m.currentOrientation, isNull, reason: 'unknown before the first event');

      final seen = <int>[];
      final sub = m.orientationStream.listen(seen.add);
      await m.start();

      fake.emitEvent(_kOrientationChanged, reason: 90);
      await settle();
      expect(m.currentOrientation, 90);

      fake.emitEvent(_kOrientationChanged, reason: 180);
      fake.emitEvent(_kOrientationChanged, reason: 270);
      fake.emitEvent(_kOrientationChanged, reason: 0);
      await settle();

      expect(seen, [90, 180, 270, 0]);
      expect(m.currentOrientation, 0);

      await sub.cancel();
      await m.dispose();
    });

    test('ignores events of other known types', () async {
      final m = OrientationManager(native: fake);
      final seen = <int>[];
      final sub = m.orientationStream.listen(seen.add);
      await m.start();

      fake.emitEvent(_kStarted, reason: 90);
      fake.emitEvent(_kDeviceConnected, message: 'back-1');
      await settle();

      expect(seen, isEmpty);
      expect(m.currentOrientation, isNull);

      await sub.cancel();
      await m.dispose();
    });

    test('an unknown event index from a newer native layer is dropped, not thrown', () async {
      final m = OrientationManager(native: fake);
      final seen = <int>[];
      final errors = <Object>[];
      final sub = m.orientationStream.listen(seen.add, onError: errors.add);
      await m.start();

      fake.emitEvent(CameraEventType.values.length + 5, reason: 90);
      fake.emitEvent(-1, reason: 90);
      await settle();

      expect(seen, isEmpty);
      expect(errors, isEmpty);

      // The listener survived: a real event still comes through.
      fake.emitEvent(_kOrientationChanged, reason: 270);
      await settle();
      expect(seen, [270]);

      await sub.cancel();
      await m.dispose();
    });
  });

  group('OrientationManager.drive', () {
    test('device mode forwards every rotation to the controller', () async {
      final controller = await openController();
      final m = OrientationManager(native: fake);
      await m.start();
      m.drive(controller, OutputOrientationMode.device);

      // Nothing seen yet, so nothing to apply.
      expect(fake.called('setTargetOrientation'), isFalse);

      fake.emitEvent(_kOrientationChanged, reason: 270);
      await settle();

      expect(fake.argsOf('setTargetOrientation'), [controller.textureId, 270]);

      fake.emitEvent(_kOrientationChanged, reason: 180);
      await settle();
      expect(fake.argsOf('setTargetOrientation'), [controller.textureId, 180]);
      expect(
        fake.calls.where((c) => c.name == 'setTargetOrientation').length,
        2,
      );

      await m.dispose();
      await controller.dispose();
    });

    test('device mode applies the already-known orientation immediately', () async {
      final controller = await openController();
      final m = OrientationManager(native: fake);
      await m.start();

      fake.emitEvent(_kOrientationChanged, reason: 90);
      await settle();
      expect(fake.called('setTargetOrientation'), isFalse, reason: 'no controller yet');

      m.drive(controller, OutputOrientationMode.device);

      expect(fake.argsOf('setTargetOrientation'), [controller.textureId, 90]);

      await m.dispose();
      await controller.dispose();
    });

    test('device mode is the default for drive()', () async {
      final controller = await openController();
      final m = OrientationManager(native: fake);
      await m.start();
      m.drive(controller);

      fake.emitEvent(_kOrientationChanged, reason: 90);
      await settle();

      expect(fake.argsOf('setTargetOrientation'), [controller.textureId, 90]);

      await m.dispose();
      await controller.dispose();
    });

    test('preview mode restores automatic orientation and forwards nothing after', () async {
      final controller = await openController();
      final m = OrientationManager(native: fake);
      await m.start();

      m.drive(controller, OutputOrientationMode.preview);
      expect(fake.argsOf('setTargetOrientation'), [controller.textureId, -1],
          reason: '-1 hands control back to the display');

      fake.clear();
      fake.emitEvent(_kOrientationChanged, reason: 180);
      fake.emitEvent(_kOrientationChanged, reason: 270);
      await settle();

      expect(fake.called('setTargetOrientation'), isFalse);
      // The stream still reports the physical orientation for UI use.
      expect(m.currentOrientation, 270);

      await m.dispose();
      await controller.dispose();
    });

    test('drive(null) detaches the controller without touching native', () async {
      final controller = await openController();
      final m = OrientationManager(native: fake);
      await m.start();
      m.drive(controller, OutputOrientationMode.device);

      fake.emitEvent(_kOrientationChanged, reason: 90);
      await settle();
      expect(fake.called('setTargetOrientation'), isTrue);

      fake.clear();
      m.drive(null);
      expect(fake.called('setTargetOrientation'), isFalse);

      fake.emitEvent(_kOrientationChanged, reason: 180);
      await settle();
      expect(fake.called('setTargetOrientation'), isFalse);

      await m.dispose();
      await controller.dispose();
    });

    test('switching from device to preview stops forwarding rotations', () async {
      final controller = await openController();
      final m = OrientationManager(native: fake);
      await m.start();
      m.drive(controller, OutputOrientationMode.device);

      fake.emitEvent(_kOrientationChanged, reason: 90);
      await settle();
      expect(fake.argsOf('setTargetOrientation'), [controller.textureId, 90]);

      m.drive(controller, OutputOrientationMode.preview);
      expect(fake.argsOf('setTargetOrientation'), [controller.textureId, -1]);

      fake.clear();
      fake.emitEvent(_kOrientationChanged, reason: 180);
      await settle();
      expect(fake.called('setTargetOrientation'), isFalse);

      await m.dispose();
      await controller.dispose();
    });
  });

  group('OrientationManager.dispose', () {
    test('disables the sensor, closes the stream and stops driving', () async {
      final controller = await openController();
      final m = OrientationManager(native: fake);
      final seen = <int>[];
      var closed = false;
      final sub = m.orientationStream.listen(seen.add, onDone: () => closed = true);
      await m.start();
      m.drive(controller, OutputOrientationMode.device);

      await m.dispose();

      expect(fake.argsOf('enableOrientationEvents'), [0]);
      await settle();
      expect(closed, isTrue, reason: 'listeners must be told the manager is finished');

      // Post-dispose native events must be inert, not throw.
      fake.clear();
      fake.emitEvent(_kOrientationChanged, reason: 90);
      await settle();
      expect(seen, isEmpty);
      expect(fake.called('setTargetOrientation'), isFalse);

      await sub.cancel();
      await controller.dispose();
    });

    test('is safe to call twice and without ever starting', () async {
      final never = OrientationManager(native: fake);
      await never.dispose();
      await never.dispose();

      expect(
        fake.calls.where((c) => c.name == 'enableOrientationEvents').length,
        2,
        reason: 'dispose always disables; only start is idempotent',
      );
      expect(fake.argsOf('enableOrientationEvents'), [0]);
    });
  });

  group('CameraDevicesObserver', () {
    test('enables hot-plug callbacks once and emits connect/disconnect events', () async {
      final obs = CameraDevicesObserver(native: fake);
      final seen = <CameraSessionEvent>[];
      final sub = obs.changes.listen(seen.add);

      await obs.start();
      await obs.start();

      expect(
        fake.calls.where((c) => c.name == 'enableDeviceAvailabilityEvents').length,
        1,
      );
      expect(fake.argsOf('enableDeviceAvailabilityEvents'), [1]);

      fake.emitEvent(_kDeviceConnected, message: 'usb-cam-1');
      fake.emitEvent(_kDeviceDisconnected, message: 'usb-cam-1');
      await settle();

      expect(seen.map((e) => e.type).toList(), [
        CameraEventType.deviceConnected,
        CameraEventType.deviceDisconnected,
      ]);
      expect(seen.map((e) => e.deviceId).toList(), ['usb-cam-1', 'usb-cam-1']);

      await sub.cancel();
      await obs.dispose();
    });

    test('ignores every other event type, known or unknown', () async {
      final obs = CameraDevicesObserver(native: fake);
      final seen = <CameraSessionEvent>[];
      final sub = obs.changes.listen(seen.add);
      await obs.start();

      fake.emitEvent(_kStarted);
      fake.emitEvent(_kOrientationChanged, reason: 90);
      fake.emitEvent(CameraEventType.values.length, message: 'from the future');
      await settle();

      expect(seen, isEmpty);

      await sub.cancel();
      await obs.dispose();
    });

    test('dispose stops the callbacks and closes the stream', () async {
      final obs = CameraDevicesObserver(native: fake);
      var closed = false;
      final seen = <CameraSessionEvent>[];
      final sub = obs.changes.listen(seen.add, onDone: () => closed = true);
      await obs.start();

      await obs.dispose();

      expect(fake.argsOf('enableDeviceAvailabilityEvents'), [0]);
      await settle();
      expect(closed, isTrue);

      fake.emitEvent(_kDeviceConnected, message: 'late');
      await settle();
      expect(seen, isEmpty);

      await sub.cancel();
    });

    test('dispose without start is safe and idempotent', () async {
      final obs = CameraDevicesObserver(native: fake);

      await obs.dispose();
      await obs.dispose();

      expect(fake.argsOf('enableDeviceAvailabilityEvents'), [0]);
    });
  });
}
