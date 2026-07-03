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
}
