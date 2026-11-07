import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Rect;

/// Shapes and text drawn INTO the camera output — the preview and recorded
/// video show them, burned in — the role vision-camera's Skia frame
/// processors play for overlays (bounding boxes, labels, guides).
///
/// Coordinates are normalised to the upright camera frame, 0..1 with (0, 0)
/// top-left — the space frame processors and detectors report in — so a
/// detection's box can be drawn as-is. The overlay persists until replaced;
/// an empty overlay clears it. Apply with `CameraController.setOverlay`.
///
/// ```dart
/// controller.setOverlay(CameraOverlay()
///   ..rect(Rect.fromLTWH(0.2, 0.3, 0.4, 0.2), color: Colors.greenAccent)
///   ..text('QR', at: const Offset(0.2, 0.27), color: Colors.greenAccent));
/// ```
class CameraOverlay {
  final List<_Command> _commands = [];

  /// Whether nothing is drawn (applying it clears the overlay).
  bool get isEmpty => _commands.isEmpty;

  /// A rectangle outline ([strokeWidth] > 0) or filled ([strokeWidth] 0).
  /// [strokeWidth] is a fraction of the frame's shorter side.
  void rect(Rect r, {required Color color, double strokeWidth = 0.006}) =>
      _commands.add(_Command(_Op.rect, color, [r.left, r.top, r.right, r.bottom, strokeWidth]));

  /// A circle outline ([strokeWidth] > 0) or disc ([strokeWidth] 0). [radius]
  /// is a fraction of the frame's shorter side.
  void circle(Offset center, double radius, {required Color color, double strokeWidth = 0.006}) =>
      _commands.add(_Command(_Op.circle, color, [center.dx, center.dy, radius, strokeWidth]));

  /// A straight line from [from] to [to].
  void line(Offset from, Offset to, {required Color color, double strokeWidth = 0.006}) =>
      _commands.add(_Command(_Op.line, color, [from.dx, from.dy, to.dx, to.dy, strokeWidth]));

  /// [text] with its top-left at [at]. [size] is the text height as a
  /// fraction of the frame's shorter side.
  void text(String text, {required Offset at, required Color color, double size = 0.04}) =>
      _commands.add(_Command(_Op.text, color, [at.dx, at.dy, size], text));

  /// The wire form `NitroCamera.updateOverlay` takes, decoded by the native
  /// renderers (`OverlayCommands` on both platforms). Little-endian:
  /// `u8 version=1, u32 count`, then per command `u8 op, u32 argb`, the op's
  /// float32 values (rect: l t r b stroke · circle: x y radius stroke ·
  /// line: x1 y1 x2 y2 stroke · text: x y size) and, for text,
  /// `u32 byteLength` + UTF-8 bytes.
  Uint8List encode() {
    final b = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(_u32(_commands.length));
    for (final c in _commands) {
      b
        ..addByte(c.op.index)
        ..add(_u32(_argb(c.color)));
      for (final v in c.values) {
        b.add((ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List());
      }
      final t = c.text;
      if (t != null) {
        final bytes = utf8.encode(t);
        b
          ..add(_u32(bytes.length))
          ..add(bytes);
      }
    }
    return b.toBytes();
  }

  static Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

  static int _argb(Color c) =>
      ((c.a * 255).round() & 0xff) << 24 | ((c.r * 255).round() & 0xff) << 16 | ((c.g * 255).round() & 0xff) << 8 | ((c.b * 255).round() & 0xff);
}

enum _Op { rect, circle, line, text }

class _Command {
  final _Op op;
  final Color color;
  final List<double> values;
  final String? text;
  const _Command(this.op, this.color, this.values, [this.text]);
}
