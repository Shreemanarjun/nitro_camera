import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/native.dart' show RecordingOptions;
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';
import 'controller_fixtures.dart';

/// Video recording: the start/pause/resume/cancel state machine, its guards,
/// and the two ways finalisation can fail.
void main() {
  late FakeNitroCamera fake;
  late CameraController c;

  setUp(() async {
    fake = FakeNitroCamera();
    c = CameraController(device: testDevice(), native: fake);
    await c.initialize();
    fake.clear();
  });

  tearDown(() async {
    await c.dispose();
    await fake.close();
  });

  Matcher recorderException(String code) => throwsA(
    isA<RecorderException>().having((e) => e.code, 'code', code),
  );

  group('startRecording', () {
    test('starts with default options and flips isRecording', () async {
      var n = 0;
      c.addListener(() => n++);

      await c.startRecording('/tmp/out.mp4');

      final args = fake.argsOf('startVideoRecording')!;
      expect(args[0], 7);
      expect(args[1], '/tmp/out.mp4');
      expect((args[2] as RecordingOptions).codec, 0);
      expect(c.isRecording, isTrue);
      expect(c.isRecordingPaused, isFalse);
      expect(n, 1);
    });

    test('forwards explicit options', () async {
      await c.startRecording(
        '/tmp/out.mov',
        options: const RecordingOptions(
          codec: 1,
          fileType: 1,
          bitRate: 8000000,
          maxDurationMs: 60000,
          hasLocation: 1,
          latitude: 1.5,
          longitude: 2.5,
        ),
      );

      final o = fake.argsOf('startVideoRecording')![2] as RecordingOptions;
      expect(o.codec, 1);
      expect(o.fileType, 1);
      expect(o.bitRate, 8000000);
      expect(o.maxDurationMs, 60000);
      expect(o.hasLocation, 1);
      expect(o.latitude, 1.5);
      expect(o.longitude, 2.5);
    });

    test('a second start while recording is ignored', () async {
      await c.startRecording('/tmp/a.mp4');
      fake.clear();

      await c.startRecording('/tmp/b.mp4');

      expect(fake.calls, isEmpty);
      expect(c.isRecording, isTrue);
    });

    test('a bare native failure becomes recorder/start-failed', () async {
      fake.failWith('startVideoRecording', StateError('no HEVC encoder'));

      await expectLater(
        c.startRecording('/tmp/out.mp4'),
        throwsA(
          isA<RecorderException>()
              .having((e) => e.code, 'code', 'recorder/start-failed')
              .having((e) => e.message, 'message', contains('no HEVC encoder'))
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );
      expect(c.isRecording, isFalse, reason: 'the session is unharmed');
    });

    test('an already-typed CameraException is rethrown unchanged', () async {
      final original = SessionException.nativeError('recorder busy');
      fake.failWith('startVideoRecording', original);

      await expectLater(
        c.startRecording('/tmp/out.mp4'),
        throwsA(same(original)),
      );
      expect(c.isRecording, isFalse);
    });

    test('rejects a start before initialize', () async {
      final fresh = CameraController(device: testDevice(), native: fake);
      await expectLater(
        fresh.startRecording('/tmp/out.mp4'),
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

  group('pause / resume / cancel guards', () {
    test('pauseRecording is a no-op when not recording', () {
      c.pauseRecording();
      expect(fake.calls, isEmpty);
      expect(c.isRecordingPaused, isFalse);
    });

    test('resumeRecording is a no-op when not recording', () {
      c.resumeRecording();
      expect(fake.calls, isEmpty);
    });

    test('cancelRecording is a no-op when not recording', () {
      c.cancelRecording();
      expect(fake.calls, isEmpty);
    });

    test('pause then resume drives the native recorder once each', () async {
      await c.startRecording('/tmp/out.mp4');
      fake.clear();
      var n = 0;
      c.addListener(() => n++);

      c.pauseRecording();
      expect(fake.callNames, ['pauseRecording']);
      expect(fake.argsOf('pauseRecording'), [7]);
      expect(c.isRecordingPaused, isTrue);
      expect(n, 1);

      c.pauseRecording();
      expect(fake.callNames, ['pauseRecording'], reason: 'already paused');
      expect(n, 1);

      c.resumeRecording();
      expect(fake.callNames, ['pauseRecording', 'resumeRecording']);
      expect(fake.argsOf('resumeRecording'), [7]);
      expect(c.isRecordingPaused, isFalse);
      expect(n, 2);

      c.resumeRecording();
      expect(
        fake.callNames,
        ['pauseRecording', 'resumeRecording'],
        reason: 'not paused',
      );
      expect(n, 2);
    });

    test('cancelRecording discards the take and resets the state', () async {
      await c.startRecording('/tmp/out.mp4');
      c.pauseRecording();
      fake.clear();
      var n = 0;
      c.addListener(() => n++);

      c.cancelRecording();

      expect(fake.callNames, ['cancelRecording']);
      expect(fake.argsOf('cancelRecording'), [7]);
      expect(c.isRecording, isFalse);
      expect(c.isRecordingPaused, isFalse);
      expect(n, 1);

      c.cancelRecording();
      expect(fake.callNames, ['cancelRecording'], reason: 'nothing to cancel');
    });
  });

  group('stopRecording', () {
    test('returns the finalised result and resets the state', () async {
      await c.startRecording('/tmp/out.mp4');
      c.pauseRecording();
      fake.clear();
      var n = 0;
      c.addListener(() => n++);

      final result = await c.stopRecording();

      expect(fake.argsOf('stopVideoRecording'), [7]);
      expect(result.path, '/tmp/fake.mp4');
      expect(result.durationMs, 1000);
      expect(result.reason, RecordingFinishedReason.stopped);
      expect(result.isFinalized, isTrue);
      expect(c.isRecording, isFalse);
      expect(c.isRecordingPaused, isFalse);
      expect(n, 1);
    });

    test('a failed finish reason throws recorder/finalize-failed', () async {
      fake.recordingResult = const RecordingResult(
        path: '/tmp/broken.mp4',
        durationMs: 0,
        fileSize: 0,
        width: 1920,
        height: 1080,
        codec: 0,
        fileType: 0,
        finishedReason: 3,
      );
      await c.startRecording('/tmp/out.mp4');

      await expectLater(
        c.stopRecording(),
        recorderException('recorder/finalize-failed'),
      );
      expect(c.isRecording, isFalse, reason: 'the take is over either way');
    });

    test('a bare native failure becomes recorder/finalize-failed and resets '
        'the state', () async {
      await c.startRecording('/tmp/out.mp4');
      c.pauseRecording();
      fake.failWith('stopVideoRecording', StateError('moov atom missing'));

      await expectLater(
        c.stopRecording(),
        throwsA(
          isA<RecorderException>()
              .having((e) => e.code, 'code', 'recorder/finalize-failed')
              .having(
                (e) => e.message,
                'message',
                contains('moov atom missing'),
              )
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );
      expect(c.isRecording, isFalse);
      expect(c.isRecordingPaused, isFalse);
    });

    test('an already-typed CameraException is rethrown after the reset',
        () async {
      final original = SessionException.nativeError('session died');
      await c.startRecording('/tmp/out.mp4');
      fake.failWith('stopVideoRecording', original);
      var n = 0;
      c.addListener(() => n++);

      await expectLater(c.stopRecording(), throwsA(same(original)));
      expect(c.isRecording, isFalse);
      expect(n, 1, reason: 'listeners still see the state reset');
    });

    test('rejects a stop before initialize', () async {
      final fresh = CameraController(device: testDevice(), native: fake);
      await expectLater(
        fresh.stopRecording(),
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
}
