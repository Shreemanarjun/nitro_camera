import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

void main() {
  group('CameraSessionEvent.fromNative', () {
    test('orientationChanged carries degrees without crashing reason mapping',
        () {
      // `reason` doubles as the degrees payload (e.g. 270) — far outside the
      // InterruptionReason enum range.
      final e = CameraSessionEvent.fromNative(CameraEvent(
        type: CameraEventType.orientationChanged.index,
        textureId: 0,
        reason: 270,
      ));
      expect(e.type, CameraEventType.orientationChanged);
      expect(e.orientationDegrees, 270);
      expect(e.reason, InterruptionReason.none);
    });

    test('interruption events still map their reason', () {
      final e = CameraSessionEvent.fromNative(CameraEvent(
        type: CameraEventType.interruptionStarted.index,
        textureId: 1,
        reason: InterruptionReason.videoDeviceInUseByAnotherClient.index,
      ));
      expect(e.reason, InterruptionReason.videoDeviceInUseByAnotherClient);
      expect(e.isInterruption, isTrue);
      expect(e.orientationDegrees, isNull);
    });

    test('hot-plug events expose the device id', () {
      final e = CameraSessionEvent.fromNative(CameraEvent(
        type: CameraEventType.deviceConnected.index,
        textureId: 0,
        message: '42',
      ));
      expect(e.deviceId, '42');
    });
  });

  group('CameraSessionEvent.map', () {
    CameraSessionEvent ev(CameraEventType type, {int reason = 0, String msg = ''}) =>
        CameraSessionEvent.fromNative(
            CameraEvent(type: type.index, textureId: 1, reason: reason, message: msg));

    test('routes each kind to its typed branch with decoded data', () {
      expect(ev(CameraEventType.error, msg: 'boom').map(
              error: (m) => 'err:$m', orElse: () => 'x'),
          'err:boom');
      expect(ev(CameraEventType.orientationChanged, reason: 270).map(
              orientationChanged: (d) => d, orElse: () => -1),
          270);
      expect(ev(CameraEventType.thermalStateChanged, reason: 3).map(
              thermalChanged: (s) => s, orElse: () => ThermalState.nominal),
          ThermalState.critical);
      expect(ev(CameraEventType.frameDropped, msg: 'FrameWasLate').map(
              frameDropped: (r) => r, orElse: () => FrameDropReason.unknown),
          FrameDropReason.frameWasLate);
      expect(ev(CameraEventType.deviceConnected, msg: 'cam2').map(
              deviceHotplug: (id, on) => '$id:$on', orElse: () => 'x'),
          'cam2:true');
      expect(ev(CameraEventType.interruptionEnded).map(
              interruption: (_, ended) => ended, orElse: () => false),
          isTrue);
    });

    test('unhandled kinds fall to orElse', () {
      expect(ev(CameraEventType.photoCaptureShutter).map(orElse: () => 'else'),
          'else');
      expect(ev(CameraEventType.started).map(orElse: () => 'else'), 'else');
    });
  });
}
