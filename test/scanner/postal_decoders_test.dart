import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/src/scanner/decoders/postnet.dart';
import 'package:nitro_camera/src/scanner/decoders/rm4scc.dart';
import 'package:nitro_camera/src/scanner/engine/bar_extractor.dart';
import 'package:nitro_camera/src/scanner/engine/binarizer.dart';
import 'package:nitro_camera/src/scanner/types.dart';

/// Renders bars into a synthetic luma image and runs the REAL pipeline:
/// GrayWindow (Otsu) → extractBars → classify → decode. This exercises the
/// extraction engine, not just the symbol tables.

const _w = 640, _h = 90;

Uint8List _blank() => Uint8List.fromList(List.filled(_w * _h, 235));

/// Draws bars (4 px wide, 4 px gaps starting at x=20) with the given y-extents.
void _drawBars(Uint8List img, List<List<int>> yExtents) {
  var x = 20;
  for (final e in yExtents) {
    for (var bx = x; bx < x + 4; bx++) {
      for (var y = e[0]; y <= e[1]; y++) {
        img[y * _w + bx] = 15;
      }
    }
    x += 8;
  }
}

/// 4-state bar extents: 0 full, 1 ascender, 2 descender, 3 tracker.
List<int> _extent4(int state) => switch (state) {
  0 => [10, 70],
  1 => [10, 45],
  2 => [35, 70],
  _ => [35, 45],
};

/// POSTNET extents: 1 tall, 0 short.
List<int> _extent2(int tall) => tall == 1 ? [20, 70] : [50, 70];

List<Bar> _pipeline(Uint8List img) {
  final win = GrayWindow(img, stride: _w, left: 0, top: 0, width: _w, height: _h);
  final bars = extractBars(win, minBars: 3);
  expect(bars, isNotNull, reason: 'bar extraction failed');
  return bars!;
}

// ── encoding helpers (mirror the decoder tables) ──

const _postnetDigits = [
  '11000',
  '00011',
  '00101',
  '00110',
  '01001',
  '01010',
  '01100',
  '10001',
  '10010',
  '10100',
];

List<int> _encodePostnet(String digits, {bool planet = false}) {
  final ds = digits.split('').map(int.parse).toList();
  final check = (10 - ds.fold<int>(0, (a, b) => a + b) % 10) % 10;
  final bits = <int>[1];
  for (final d in [...ds, check]) {
    bits.addAll(_postnetDigits[d].split('').map(int.parse));
  }
  bits.add(1);
  return planet ? [1, ...bits.sublist(1, bits.length - 1).map((b) => 1 - b), 1] : bits;
}

const _rm4Charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const _rm4Table = [
  [3, 3, 0, 0],
  [3, 2, 1, 0],
  [3, 2, 0, 1],
  [2, 3, 1, 0],
  [2, 3, 0, 1],
  [2, 2, 1, 1],
  [3, 1, 2, 0],
  [3, 0, 3, 0],
  [3, 0, 2, 1],
  [2, 1, 3, 0],
  [2, 1, 2, 1],
  [2, 0, 3, 1],
  [3, 1, 0, 2],
  [3, 0, 1, 2],
  [3, 0, 0, 3],
  [2, 1, 1, 2],
  [2, 1, 0, 3],
  [2, 0, 1, 3],
  [1, 3, 2, 0],
  [1, 2, 3, 0],
  [1, 2, 2, 1],
  [0, 3, 3, 0],
  [0, 3, 2, 1],
  [0, 2, 3, 1],
  [1, 3, 0, 2],
  [1, 2, 1, 2],
  [1, 2, 0, 3],
  [0, 3, 1, 2],
  [0, 3, 0, 3],
  [0, 2, 1, 3],
  [1, 1, 2, 2],
  [1, 0, 3, 2],
  [1, 0, 2, 3],
  [0, 1, 3, 2],
  [0, 1, 2, 3],
  [0, 0, 3, 3],
];
const _rm4Check = [
  [1, 1],
  [1, 2],
  [1, 3],
  [1, 4],
  [1, 5],
  [1, 0],
  [2, 1],
  [2, 2],
  [2, 3],
  [2, 4],
  [2, 5],
  [2, 0],
  [3, 1],
  [3, 2],
  [3, 3],
  [3, 4],
  [3, 5],
  [3, 0],
  [4, 1],
  [4, 2],
  [4, 3],
  [4, 4],
  [4, 5],
  [4, 0],
  [5, 1],
  [5, 2],
  [5, 3],
  [5, 4],
  [5, 5],
  [5, 0],
  [0, 1],
  [0, 2],
  [0, 3],
  [0, 4],
  [0, 5],
  [0, 0],
];

List<int> _encodeRm4scc(String text) {
  final values = text.split('').map(_rm4Charset.indexOf).toList();
  var top = 0, bottom = 0;
  for (final v in values) {
    top += _rm4Check[v][0];
    bottom += _rm4Check[v][1];
  }
  var row = (top % 6) - 1, col = (bottom % 6) - 1;
  if (row == -1) row = 5;
  if (col == -1) col = 5;
  final states = <int>[1];
  for (final v in [...values, 6 * row + col]) {
    states.addAll(_rm4Table[v]);
  }
  states.add(0);
  return states;
}

void main() {
  group('POSTNET / PLANET', () {
    test('round-trips a ZIP through the image pipeline', () {
      final img = _blank();
      _drawBars(img, _encodePostnet('12345').map(_extent2).toList());
      final result = decodePostnetPlanet(classify2State(_pipeline(img)));
      expect(result, isNotNull);
      expect(result!.format, CodeFormat.postnet);
      expect(result.text, '12345');
    });

    test('round-trips PLANET', () {
      final img = _blank();
      _drawBars(img, _encodePostnet('40100000000', planet: true).map(_extent2).toList());
      final result = decodePostnetPlanet(classify2State(_pipeline(img)));
      expect(result, isNotNull);
      expect(result!.format, CodeFormat.planet);
      expect(result.text, '40100000000');
    });

    test('rejects a corrupted checksum', () {
      final bits = _encodePostnet('12345');
      // Flip one digit's bars (breaks the mod-10 sum).
      final img = _blank();
      final swapped = List.of(bits);
      swapped.setRange(1, 6, _postnetDigits[9].split('').map(int.parse));
      _drawBars(img, swapped.map(_extent2).toList());
      expect(decodePostnetPlanet(classify2State(_pipeline(img))), isNull);
    });
  });

  group('RM4SCC / KIX', () {
    test('round-trips a UK postcode through the image pipeline', () {
      final img = _blank();
      _drawBars(img, _encodeRm4scc('BX11LT').map(_extent4).toList());
      final result = decodeRm4scc(classify4State(_pipeline(img)));
      expect(result, isNotNull);
      expect(result!.format, CodeFormat.rm4scc);
      expect(result.text, 'BX11LT');
    });

    test('rejects a wrong check character', () {
      final states = _encodeRm4scc('BX11LT');
      // Replace the check char (last 4 states before the stop bar).
      final broken = List.of(states);
      broken.replaceRange(broken.length - 5, broken.length - 1, _rm4Table[0]);
      final img = _blank();
      _drawBars(img, broken.map(_extent4).toList());
      expect(decodeRm4scc(classify4State(_pipeline(img))), isNull);
    });

    test('decodes KIX (no frame, no checksum)', () {
      const chars = 'X1234B';
      final states = <int>[];
      for (final c in chars.split('')) {
        states.addAll(_rm4Table[_rm4Charset.indexOf(c)]);
      }
      final img = _blank();
      _drawBars(img, states.map(_extent4).toList());
      final result = decodeKix(classify4State(_pipeline(img)));
      expect(result, isNotNull);
      expect(result!.format, CodeFormat.kix);
      expect(result.text, chars);
    });
  });
}
