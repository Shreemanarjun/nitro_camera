import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// CameraOverlay's wire form — the layout the native parsers
/// (OverlayCommands.kt, OverlayRenderer.swift) decode.
void main() {
  ByteData bytes(CameraOverlay o) => ByteData.sublistView(o.encode());

  test('an empty overlay is version + zero count (clears)', () {
    final o = CameraOverlay();
    expect(o.isEmpty, isTrue);
    expect(o.encode(), [1, 0, 0, 0, 0]);
  });

  test('a rect encodes op, ARGB and five float32 values', () {
    final b = bytes(CameraOverlay()..rect(const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6), color: const Color(0xFF00FF00), strokeWidth: 0.01));
    expect(b.getUint8(0), 1);
    expect(b.getUint32(1, Endian.little), 1);
    expect(b.getUint8(5), 0, reason: 'op rect');
    expect(b.getUint32(6, Endian.little), 0xFF00FF00);
    final values = [for (var i = 0; i < 5; i++) b.getFloat32(10 + i * 4, Endian.little)];
    for (final (got, want) in [(values[0], 0.1), (values[1], 0.2), (values[2], 0.5), (values[3], 0.6), (values[4], 0.01)]) {
      expect(got, closeTo(want, 1e-6));
    }
    expect(b.lengthInBytes, 10 + 20);
  });

  test('text carries its UTF-8 bytes after the floats', () {
    final b = bytes(CameraOverlay()..text('QR ✓', at: const Offset(0.2, 0.3), color: const Color(0x80FFFFFF), size: 0.05));
    expect(b.getUint8(5), 3, reason: 'op text');
    expect(b.getUint32(6, Endian.little), 0x80FFFFFF);
    final len = b.getUint32(10 + 12, Endian.little);
    final text = utf8.decode(b.buffer.asUint8List(b.offsetInBytes + 26, len));
    expect(text, 'QR ✓');
  });

  test('commands keep their order', () {
    final o = CameraOverlay()
      ..circle(const Offset(0.5, 0.5), 0.1, color: const Color(0xFFFF0000))
      ..line(Offset.zero, const Offset(1, 1), color: const Color(0xFFFFFFFF));
    final b = bytes(o);
    expect(b.getUint32(1, Endian.little), 2);
    expect(b.getUint8(5), 1, reason: 'circle first');
    expect(b.getUint8(5 + 5 + 16), 2, reason: 'then the line');
  });
}
