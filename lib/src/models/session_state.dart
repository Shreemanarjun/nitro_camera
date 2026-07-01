import 'dart:convert';

/// The pixel format of the raw frame-processing stream.
///
/// Type-safe replacement for the `0 / 1` integers used at the FFI boundary.
enum PixelFormat {
  /// `YUV_420_888` — planar luma/chroma, cheapest for ML / analysis.
  yuv420(0),

  /// `BGRA_8888` — interleaved 32-bit colour, ready for image display.
  bgra(1);

  const PixelFormat(this.nativeValue);

  /// The integer sent across the FFI bridge.
  final int nativeValue;

  static PixelFormat fromNative(int value) =>
      value == 0 ? PixelFormat.yuv420 : PixelFormat.bgra;
}

/// A typed snapshot of the live native camera session — the parsed form of
/// `NitroCamera.getSessionStateJson`. Prefer this over hand-parsing JSON.
class SessionState {
  final bool running;
  final int width;
  final int height;
  final int fps;
  final PixelFormat pixelFormat;

  const SessionState({
    required this.running,
    required this.width,
    required this.height,
    required this.fps,
    required this.pixelFormat,
  });

  /// The session's aspect ratio, or 0 when the height is unknown.
  double get aspectRatio => height == 0 ? 0 : width / height;

  factory SessionState.fromJson(String jsonStr) {
    try {
      final m = jsonDecode(jsonStr) as Map<String, dynamic>;
      return SessionState(
        running: m['running'] == true,
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        fps: (m['fps'] as num?)?.toInt() ?? 0,
        pixelFormat: PixelFormat.fromNative((m['pixelFormat'] as num?)?.toInt() ?? 1),
      );
    } catch (_) {
      return const SessionState(
        running: false,
        width: 0,
        height: 0,
        fps: 0,
        pixelFormat: PixelFormat.bgra,
      );
    }
  }

  @override
  String toString() =>
      'SessionState(running: $running, ${width}x$height@${fps}fps, ${pixelFormat.name})';
}
