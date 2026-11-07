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

  static PixelFormat fromNative(int value) => value == 0 ? PixelFormat.yuv420 : PixelFormat.bgra;
}

/// YCbCr value range of the frame stream (vision-camera's full / video range):
/// full = 0..255, video = 16..235 luma / 16..240 chroma.
enum ColorRange { full, video, unknown }

/// A typed snapshot of the live native camera session — the parsed form of
/// `NitroCamera.getSessionStateJson`. Prefer this over hand-parsing JSON.
class SessionState {
  final bool running;
  final int width;
  final int height;
  final int fps;
  final PixelFormat pixelFormat;

  /// Frame-processor stream size — differs from the preview [width]×[height]
  /// when the session was opened with a separate frame size (Android). Equals
  /// the preview size when the platform doesn't report it.
  final int frameWidth;
  final int frameHeight;

  /// Range of the frame stream's values ([ColorRange.unknown] when the native
  /// layer doesn't report it).
  final ColorRange colorRange;

  /// Whether the session captures audio (recordings get an audio track).
  final bool audio;

  /// Why audio was requested but isn't captured — microphone permission
  /// denied, no microphone, the audio session failed. The session then
  /// records video only. `null` when audio is fine or wasn't requested.
  final String? audioError;

  const SessionState({
    required this.running,
    required this.width,
    required this.height,
    required this.fps,
    required this.pixelFormat,
    int? frameWidth,
    int? frameHeight,
    this.colorRange = ColorRange.unknown,
    this.audio = false,
    this.audioError,
  }) : frameWidth = frameWidth ?? width,
       frameHeight = frameHeight ?? height;

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
        frameWidth: (m['frameWidth'] as num?)?.toInt(),
        frameHeight: (m['frameHeight'] as num?)?.toInt(),
        colorRange: ColorRange.values.asNameMap()[m['colorRange']] ?? ColorRange.unknown,
        audio: m['audio'] == true,
        audioError: m['audioError'] as String?,
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
  String toString() => 'SessionState(running: $running, ${width}x$height@${fps}fps, ${pixelFormat.name})';
}
