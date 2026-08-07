// Constructions here are deliberately NON-const: a const invocation is folded
// at compile time and never executes the generative constructor, which both
// hides it from coverage and stops the test from exercising real construction.
// ignore_for_file: prefer_const_constructors

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Every subclass is constructed at RUNTIME here (no `const`) so the generative
/// constructors are actually executed, and each one is checked for the
/// code / message / cause it carries.
void main() {
  group('CameraException subclasses', () {
    test('PermissionException carries code, message and cause', () {
      final cause = StateError('no entitlement');
      final e = PermissionException('permission/camera-restricted', 'Restricted by policy.', cause: cause);

      expect(e, isA<CameraException>());
      expect(e.code, 'permission/camera-restricted');
      expect(e.message, 'Restricted by policy.');
      expect(identical(e.cause, cause), isTrue);
      expect(e.toString(), 'PermissionException(permission/camera-restricted): Restricted by policy.');
    });

    test('DeviceException carries code, message and cause', () {
      final e = DeviceException('device/disconnected', 'Camera went away.', cause: 'usb-unplug');

      expect(e.code, 'device/disconnected');
      expect(e.message, 'Camera went away.');
      expect(e.cause, 'usb-unplug');
      expect(e.toString(), 'DeviceException(device/disconnected): Camera went away.');
    });

    test('SessionException carries code, message and cause', () {
      final e = SessionException('session/configure-failed', 'Could not configure.', cause: 17);

      expect(e.code, 'session/configure-failed');
      expect(e.message, 'Could not configure.');
      expect(e.cause, 17);
      expect(e.toString(), 'SessionException(session/configure-failed): Could not configure.');
    });

    test('CaptureException carries code, message and cause', () {
      final cause = Exception('shutter jam');
      final e = CaptureException('capture/timed-out', 'Photo capture timed out.', cause: cause);

      expect(e, isA<CameraException>());
      expect(e.code, 'capture/timed-out');
      expect(e.message, 'Photo capture timed out.');
      expect(identical(e.cause, cause), isTrue);
      expect(e.toString(), 'CaptureException(capture/timed-out): Photo capture timed out.');
    });

    test('RecorderException carries code, message and cause', () {
      final e = RecorderException('recorder/writer-failed', 'Muxer failed.', cause: 'ENOSPC');

      expect(e.code, 'recorder/writer-failed');
      expect(e.message, 'Muxer failed.');
      expect(e.cause, 'ENOSPC');
      expect(e.toString(), 'RecorderException(recorder/writer-failed): Muxer failed.');
    });

    test('cause defaults to null when not wrapping a lower-level failure', () {
      expect(CaptureException('capture/aborted', 'Aborted.').cause, isNull);
      expect(RecorderException('recorder/aborted', 'Aborted.').cause, isNull);
      expect(DeviceException('device/busy', 'Busy.').cause, isNull);
      expect(SessionException('session/stopped', 'Stopped.').cause, isNull);
      expect(PermissionException('permission/mic-denied', 'Denied.').cause, isNull);
    });

    test('every subclass is an Exception and is throwable/catchable as CameraException', () {
      final all = <CameraException>[
        PermissionException('permission/x', 'p'),
        DeviceException('device/x', 'd'),
        SessionException('session/x', 's'),
        CaptureException('capture/x', 'c'),
        RecorderException('recorder/x', 'r'),
      ];

      for (final e in all) {
        expect(e, isA<Exception>());
        expect(
          () => throw e,
          throwsA(isA<CameraException>().having((x) => x.code, 'code', e.code)),
        );
      }
    });
  });

  group('factories', () {
    test('PermissionException factories carry a non-empty message', () {
      expect(PermissionException.cameraDenied().message, isNotEmpty);
      expect(PermissionException.cameraDenied().cause, isNull);
      expect(PermissionException.microphoneDenied().message, contains('Microphone'));
    });

    test('DeviceException.openFailed names the device that failed', () {
      final e = DeviceException.openFailed('front-1');

      expect(e.code, 'device/open-failed');
      expect(e.message, 'openCamera failed for device front-1');
      expect(e.cause, isNull);
    });

    test('SessionException.malformedPayload wraps the underlying cause', () {
      final cause = FormatException('unexpected token');
      final e = SessionException.malformedPayload('session-state', cause);

      expect(e.code, 'session/malformed-payload');
      expect(e.message, contains('session-state'));
      expect(identical(e.cause, cause), isTrue);
    });

    test('SessionException.nativeError substitutes a default for an empty message', () {
      expect(SessionException.nativeError('').message, 'camera error');
      expect(SessionException.nativeError('AVError -11800').message, 'AVError -11800');
    });
  });

  test('the sealed hierarchy switches exhaustively without a default arm', () {
    // Compile-time proof: adding a subclass without updating handlers breaks
    // the build rather than silently falling through.
    String label(CameraException e) => switch (e) {
      PermissionException(:final code) => 'permission:$code',
      DeviceException(:final code) => 'device:$code',
      SessionException(:final code) => 'session:$code',
      CaptureException(:final code) => 'capture:$code',
      RecorderException(:final code) => 'recorder:$code',
    };

    expect(label(PermissionException('permission/a', 'm')), 'permission:permission/a');
    expect(label(DeviceException('device/b', 'm')), 'device:device/b');
    expect(label(SessionException('session/c', 'm')), 'session:session/c');
    expect(label(CaptureException('capture/d', 'm')), 'capture:capture/d');
    expect(label(RecorderException('recorder/e', 'm')), 'recorder:recorder/e');
  });
}
