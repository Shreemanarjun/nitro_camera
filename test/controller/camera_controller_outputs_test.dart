import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';
import 'controller_fixtures.dart';

/// focusAt / depth output / encoded output: the native calls they make, input
/// validation and the typed errors the native `CODE: detail` failures map to.
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

  group('focusAt', () {
    test('passes the point and the adaptiveness, returns the native verdict', () async {
      expect(await c.focusAt(0.25, 0.75), isTrue);
      expect(fake.argsOf('focusAt'), [7, 0.25, 0.75, 0]);

      fake.focusAtResult = 0;
      expect(await c.focusAt(0, 1, adaptiveness: FocusAdaptiveness.locked), isFalse);
      expect(fake.argsOf('focusAt'), [7, 0.0, 1.0, 1]);
    });

    for (final (x, y) in [(-0.01, 0.5), (0.5, 1.01), (double.nan, 0.5), (0.5, double.infinity)]) {
      test('rejects ($x, $y) before reaching native', () async {
        await expectLater(c.focusAt(x, y), throwsArgumentError);
        expect(fake.called('focusAt'), isFalse);
      });
    }

    test('maps FOCUS_UNSUPPORTED to DeviceException(device/focus-unsupported)', () async {
      fake.failWith('focusAt', Exception('FOCUS_UNSUPPORTED: fixed-focus'));
      await expectLater(
        c.focusAt(0.5, 0.5),
        throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'device/focus-unsupported').having((e) => e.message, 'message', 'fixed-focus')),
      );
    });

    test('maps a native INVALID_ARGUMENT to ArgumentError', () async {
      fake.failWith('focusAt', Exception('INVALID_ARGUMENT: bad point'));
      await expectLater(c.focusAt(0.5, 0.5), throwsArgumentError);
    });

    test('rethrows an unknown native failure unchanged', () async {
      final boom = StateError('boom');
      fake.failWith('focusAt', boom);
      await expectLater(c.focusAt(0.5, 0.5), throwsA(same(boom)));
    });

    test('before initialize throws session/not-initialized', () async {
      final fresh = CameraController(device: testDevice(), native: fake);
      await expectLater(fresh.focusAt(0.5, 0.5), throwsA(isA<SessionException>().having((e) => e.code, 'code', 'session/not-initialized')));
    });
  });

  group('depth output', () {
    test('setDepthOutput forwards on/off', () async {
      await c.setDepthOutput(true);
      await c.setDepthOutput(false);
      expect(fake.callNames, ['setDepthOutput', 'setDepthOutput']);
      expect(fake.argsOf('setDepthOutput'), [7, 0]);
    });

    test('maps DEPTH_UNSUPPORTED to DeviceException(device/depth-unsupported)', () async {
      fake.failWith('setDepthOutput', Exception('DEPTH_UNSUPPORTED: no depth'));
      await expectLater(c.setDepthOutput(true), throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'device/depth-unsupported')));
    });

    test('maps SESSION_NOT_RUNNING to SessionException(session/not-running)', () async {
      fake.failWith('setDepthOutput', Exception('SESSION_NOT_RUNNING: gone'));
      await expectLater(c.setDepthOutput(true), throwsA(isA<SessionException>().having((e) => e.code, 'code', 'session/not-running')));
    });

    test('maps SESSION_BUSY (recording) to SessionException(session/busy)', () async {
      fake.failWith('setDepthOutput', Exception('SESSION_BUSY: recording'));
      await expectLater(c.setDepthOutput(true), throwsA(isA<SessionException>().having((e) => e.code, 'code', 'session/busy')));
    });

    test('depthStream keeps only this session and exposes metres', () async {
      final got = <List<double>>[];
      final sub = c.depthStream.listen((f) => got.add([f.metres[0], f.metres[3], f.metresAt(1, 1)]));
      fake.emitDepth(_depth(textureId: 99)); // another session
      fake.emitDepth(_depth(textureId: 7));
      await pumpEventQueue();
      await sub.cancel();
      expect(got, [
        [0.5, 2.0, 2.0],
      ]);
    });

    test('metresAt rejects out-of-range pixels', () {
      final f = _depth(textureId: 7);
      expect(() => f.metresAt(2, 0), throwsRangeError);
      expect(() => f.metresAt(0, -1), throwsRangeError);
    });
  });

  group('encoded output', () {
    test('start / stats / stop reach native with the options', () {
      c.startEncodedOutput(width: 1280, height: 720, bitRate: 4000000);
      expect(c.encodedOutputStats.frames, 0);
      c.stopEncodedOutput();
      expect(fake.callNames, ['startEncodedOutput', 'getEncodedOutputStats', 'stopEncodedOutput']);
      expect(fake.argsOf('startEncodedOutput'), [7, 1280, 720, 4000000]);
    });

    for (final (w, h, b) in [(0, 720, 1), (721, 720, 1), (720, -2, 1), (720, 720, 0)]) {
      test('rejects $w x $h @ $b', () {
        expect(() => c.startEncodedOutput(width: w, height: h, bitRate: b), throwsArgumentError);
        expect(fake.called('startEncodedOutput'), isFalse);
      });
    }
  });

  group('native buffers', () {
    test('setNativeBuffers forwards; release skips frames without a buffer', () {
      c.setNativeBuffers(true);
      c.releaseNativeBuffer(_frameWith(0));
      c.releaseNativeBuffer(_frameWith(0xBEEF));
      c.setNativeBuffers(false);
      expect(fake.callNames, ['setNativeBuffers', 'releaseNativeBuffer', 'setNativeBuffers']);
      expect(fake.calls[1].args, [0xBEEF]);
    });

    test('maps NATIVE_BUFFER_UNSUPPORTED to DeviceException(device/native-buffer-unsupported)', () {
      fake.failWith('setNativeBuffers', Exception('NATIVE_BUFFER_UNSUPPORTED: needs Android 9'));
      expect(() => c.setNativeBuffers(true), throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'device/native-buffer-unsupported')));
    });

    test('before initialize throws session/not-initialized', () {
      final fresh = CameraController(device: testDevice(), native: fake);
      expect(() => fresh.setNativeBuffers(true), throwsA(isA<SessionException>()));
    });
  });

  group('SessionState.audio', () {
    test('parses audio + audioError, tolerating bad types', () {
      final ok = SessionState.fromJson('{"audio":true}');
      expect((ok.audio, ok.audioError), (true, null));
      final denied = SessionState.fromJson('{"audio":false,"audioError":"microphone permission denied"}');
      expect((denied.audio, denied.audioError), (false, 'microphone permission denied'));
      expect(SessionState.fromJson('{}').audio, isFalse);
      expect(SessionState.fromJson('{"audio":"yes","audioError":5}').running, isFalse); // malformed → stopped snapshot
    });
  });

  group('SessionState.colorRange', () {
    test('parses full / video and defaults to unknown', () {
      expect(SessionState.fromJson('{"colorRange":"full"}').colorRange, ColorRange.full);
      expect(SessionState.fromJson('{"colorRange":"video"}').colorRange, ColorRange.video);
      expect(SessionState.fromJson('{}').colorRange, ColorRange.unknown);
      expect(SessionState.fromJson('{"colorRange":"weird"}').colorRange, ColorRange.unknown);
      expect(SessionState.fromJson('{"colorRange":3}').colorRange, ColorRange.unknown);
      expect(SessionState.fromJson('not json').colorRange, ColorRange.unknown);
    });
  });
}

/// A 2×2 depth map: 0.5, 1, 1.5, 2 m.
DepthFrame _depth({required int textureId}) {
  final data = Float32List.fromList([0.5, 1, 1.5, 2]).buffer.asUint8List();
  return DepthFrame(data: data, size: 16, width: 2, height: 2, bytesPerRow: 8, timestamp: 0, textureId: textureId);
}

CameraFrame _frameWith(int nativeBuffer) => CameraFrame(
  pixels: Uint8List(4),
  size: 4,
  width: 2,
  height: 2,
  timestamp: 0,
  orientation: 0,
  textureId: 7,
  nativeBuffer: nativeBuffer,
);
