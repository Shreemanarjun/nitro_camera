import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// The 0.1.0 error contract: stable `domain/code` strings, sealed hierarchy
/// (exhaustive switch), and typed factories. Codes are API — this test is the
/// tripwire against accidental renames.
void main() {
  test('factory codes are stable', () {
    expect(PermissionException.cameraDenied().code, 'permission/camera-denied');
    expect(PermissionException.microphoneDenied().code,
        'permission/microphone-denied');
    expect(DeviceException.openFailed('cam0').code, 'device/open-failed');
    expect(SessionException.notInitialized().code, 'session/not-initialized');
    expect(SessionException.malformedPayload('x', 'oops').code,
        'session/malformed-payload');
    expect(SessionException.nativeError('boom').code, 'session/native-error');
  });

  test('messages carry the human-readable detail', () {
    expect(DeviceException.openFailed('back-0').message, contains('back-0'));
    expect(SessionException.nativeError('').message, isNotEmpty,
        reason: 'an empty native message must not produce an empty error');
    final wrapped = SessionException.malformedPayload('camera-device', 'bad');
    expect(wrapped.message, contains('camera-device'));
    expect(wrapped.cause, 'bad');
  });

  test('the hierarchy is exhaustively matchable (sealed)', () {
    String domain(CameraException e) => switch (e) {
          PermissionException() => 'permission',
          DeviceException() => 'device',
          SessionException() => 'session',
          CaptureException() => 'capture',
          RecorderException() => 'recorder',
        };
    expect(domain(PermissionException.cameraDenied()), 'permission');
    expect(domain(DeviceException.openFailed('x')), 'device');
    expect(domain(SessionException.notInitialized()), 'session');
    expect(domain(const CaptureException('capture/timed-out', 't')), 'capture');
    expect(
        domain(const RecorderException('recorder/writer-failed', 'w')), 'recorder');
  });

  test('code prefix always matches the subtype domain', () {
    expect(SessionException.notInitialized().code, startsWith('session/'));
    expect(DeviceException.openFailed('x').code, startsWith('device/'));
    expect(PermissionException.cameraDenied().code, startsWith('permission/'));
  });

  test('toString names the type, code and message', () {
    final s = DeviceException.openFailed('cam9').toString();
    expect(s, contains('DeviceException'));
    expect(s, contains('device/open-failed'));
    expect(s, contains('cam9'));
  });
}
