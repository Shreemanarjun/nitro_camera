import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

void main() {
  test('SessionState parses a native session snapshot', () {
    final st = SessionState.fromJson(
      '{"running":true,"width":1920,"height":1080,"fps":30,"pixelFormat":0}',
    );

    expect(st.running, isTrue);
    expect(st.width, 1920);
    expect(st.height, 1080);
    expect(st.fps, 30);
    expect(st.pixelFormat, PixelFormat.yuv420);
    expect(st.aspectRatio, closeTo(16 / 9, 1e-9));
  });

  test('PixelFormat wire mapping is stable', () {
    // Android's frame pipeline clamps to yuv420 (0) natively; iOS reports the
    // real videoSettings format. Lock the wire contract on the Dart side.
    expect(PixelFormat.fromNative(0), PixelFormat.yuv420);
    expect(PixelFormat.fromNative(1), PixelFormat.bgra);
    // Unknown values from a newer native layer collapse to bgra, never throw.
    expect(PixelFormat.fromNative(7), PixelFormat.bgra);
    expect(PixelFormat.fromNative(-1), PixelFormat.bgra);

    expect(PixelFormat.yuv420.nativeValue, 0);
    expect(PixelFormat.bgra.nativeValue, 1);
  });

  test('malformed session JSON falls back instead of throwing', () {
    final st = SessionState.fromJson('not json at all');

    expect(st.running, isFalse);
    expect(st.width, 0);
    expect(st.height, 0);
    expect(st.aspectRatio, 0);
    expect(st.pixelFormat, PixelFormat.bgra);
  });
}
