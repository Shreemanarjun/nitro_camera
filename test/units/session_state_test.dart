import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// `SessionState.fromJson` sits directly on the native boundary: it must never
/// throw, whatever the native layer (or a version-skewed one) hands back.
void main() {
  group('SessionState.fromJson', () {
    test('missing keys fall back to zeroes and bgra, not to an exception', () {
      final st = SessionState.fromJson('{}');

      expect(st.running, isFalse);
      expect(st.width, 0);
      expect(st.height, 0);
      expect(st.fps, 0);
      expect(st.pixelFormat, PixelFormat.bgra);
      expect(st.aspectRatio, 0);
    });

    test('a partial payload keeps the keys that ARE present', () {
      final st = SessionState.fromJson('{"running":true,"width":640}');

      expect(st.running, isTrue);
      expect(st.width, 640);
      expect(st.height, 0);
      expect(st.fps, 0);
    });

    test('doubles are truncated to ints (native may report fractional fps)', () {
      final st = SessionState.fromJson(
        '{"running":true,"width":1920.0,"height":1080.9,"fps":29.97,"pixelFormat":1.0}',
      );

      expect(st.width, 1920);
      expect(st.height, 1080);
      expect(st.fps, 29);
      expect(st.pixelFormat, PixelFormat.bgra);
    });

    test('running is strictly `true`, not truthy', () {
      expect(SessionState.fromJson('{"running":1}').running, isFalse);
      expect(SessionState.fromJson('{"running":"true"}').running, isFalse);
      expect(SessionState.fromJson('{"running":false}').running, isFalse);
      expect(SessionState.fromJson('{"running":true}').running, isTrue);
    });

    test('wrong value types fall back to the safe default state', () {
      // `width` is not a num -> the cast throws -> whole snapshot falls back.
      final st = SessionState.fromJson('{"running":true,"width":"1920"}');

      expect(st.running, isFalse, reason: 'the fallback must not keep partial data');
      expect(st.width, 0);
      expect(st.pixelFormat, PixelFormat.bgra);
    });

    test('a non-object payload falls back instead of throwing a cast error', () {
      for (final payload in ['[1,2,3]', '42', '"running"', 'null', '']) {
        final st = SessionState.fromJson(payload);
        expect(st.running, isFalse, reason: payload);
        expect(st.width, 0, reason: payload);
        expect(st.height, 0, reason: payload);
        expect(st.pixelFormat, PixelFormat.bgra, reason: payload);
      }
    });

    test('truncated JSON falls back', () {
      final st = SessionState.fromJson('{"running":true,"width":19');

      expect(st.running, isFalse);
      expect(st.width, 0);
    });
  });

  group('SessionState', () {
    test('aspectRatio divides width by height', () {
      const st = SessionState(
        running: true,
        width: 1280,
        height: 720,
        fps: 60,
        pixelFormat: PixelFormat.yuv420,
      );

      expect(st.aspectRatio, closeTo(16 / 9, 1e-12));
    });

    test('toString reports the running flag, resolution, fps and format', () {
      const st = SessionState(
        running: true,
        width: 1920,
        height: 1080,
        fps: 30,
        pixelFormat: PixelFormat.yuv420,
      );

      expect(st.toString(), 'SessionState(running: true, 1920x1080@30fps, yuv420)');
    });

    test('toString of the fallback state is the stopped snapshot', () {
      expect(
        SessionState.fromJson('nonsense').toString(),
        'SessionState(running: false, 0x0@0fps, bgra)',
      );
    });
  });
}
