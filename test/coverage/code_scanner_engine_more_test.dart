import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/oned.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// Gap-closing tests for the [decodeCodeFrame] engine cascade: the decimated
/// (factor > 1) pass, the rotated pass, the postal / width / two-track
/// Pharmacode branches of the built-in engines, and the 180° case of the
/// point mapper.
///
/// Every frame is a synthetic square luma plane (`format: 0`) so the scanner's
/// centered-square window covers the whole image.

const _side = 400;

Uint8List _blank([int side = _side]) => Uint8List.fromList(List.filled(side * side, 235));

FrameData _frame(Uint8List bytes, {int side = _side}) => FrameData(
  bytes: bytes,
  width: side,
  height: side,
  format: 0,
  bytesPerRow: side,
);

/// Rasterizes a QR into a [side]×[side] luma plane.
FrameData _qrFrame(String text, {int side = _side}) {
  final matrix = QRCodeWriter().encode(text, BarcodeFormat.qrCode, side, side);
  final bytes = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      bytes[y * side + x] = matrix.get(x, y) ? 0 : 255;
    }
  }
  return _frame(bytes, side: side);
}

/// Rasterizes a Code 128 **rotated 90° counter-clockwise**, i.e. its bars run
/// top-to-bottom. Only the scanner's rotated pass can read this.
FrameData _verticalCode128(String text, {int side = _side}) {
  final matrix = Code128Writer().encode(text, BarcodeFormat.code128, side, side);
  final bytes = Uint8List.fromList(List.filled(side * side, 255));
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      // transpose: source column x becomes row x
      if (matrix.get(y, x)) bytes[y * side + x] = 0;
    }
  }
  return _frame(bytes, side: side);
}

/// Draws vertical bars of [barW] px with [gapW] px gaps, each with its own
/// `[yTop, yBottom]` extent, starting at x=[x0].
void _drawBars(Uint8List img, List<List<int>> yExtents, {int x0 = 40, int barW = 4, int gapW = 4}) {
  var x = x0;
  for (final e in yExtents) {
    for (var bx = x; bx < x + barW; bx++) {
      for (var y = e[0]; y <= e[1]; y++) {
        img[y * _side + bx] = 15;
      }
    }
    x += barW + gapW;
  }
}

/// Band [140, 300]: 4-state extents — 0 full, 1 ascender, 2 descender,
/// 3 tracker.
List<int> _extent4(int state) => switch (state) {
  0 => [140, 300],
  1 => [140, 240],
  2 => [200, 300],
  _ => [200, 240],
};

/// POSTNET extents: 1 tall, 0 short.
List<int> _extent2(int tall) => tall == 1 ? [150, 300] : [240, 300];

const _postnetDigits = ['11000', '00011', '00101', '00110', '01001', '01010', '01100', '10001', '10010', '10100'];

List<int> _encodePostnet(String digits) {
  final ds = digits.split('').map(int.parse).toList();
  final check = (10 - ds.fold<int>(0, (a, b) => a + b) % 10) % 10;
  final bits = <int>[1];
  for (final d in [...ds, check]) {
    bits.addAll(_postnetDigits[d].split('').map(int.parse));
  }
  return bits..add(1);
}

/// Two-track Pharmacode base-3 states (Zint `pharma_two_calc`):
/// digit 1 → ascender, 2 → descender, 3 → full.
List<int> _pharmaTwoStates(int value) {
  final digits = <int>[];
  var t = value;
  do {
    switch (t % 3) {
      case 0:
        digits.add(3);
        t = (t - 3) ~/ 3;
      case 1:
        digits.add(1);
        t = (t - 1) ~/ 3;
      case 2:
        digits.add(2);
        t = (t - 2) ~/ 3;
    }
  } while (t != 0);
  return [for (final d in digits.reversed) d == 3 ? 0 : d];
}

/// One-track Pharmacode run widths (bar W=3 / N=1, spaces 2, final space
/// chopped), per Zint `zint_pharma`.
List<int> _pharmaOneUnits(int value) {
  final digits = <int>[];
  var t = value;
  do {
    if (t.isEven) {
      digits.add(2);
      t = (t - 2) ~/ 2;
    } else {
      digits.add(1);
      t = (t - 1) ~/ 2;
    }
  } while (t != 0);
  final units = <int>[];
  for (final d in digits.reversed) {
    units
      ..add(d == 2 ? 3 : 1)
      ..add(2);
  }
  return units.sublist(0, units.length - 1);
}

/// Paints alternating bar/space [units] (module = [module] px) across the
/// full band height.
Uint8List _unitsImage(List<int> units, {int module = 4, int x0 = 40, int yTop = 120, int yBottom = 300}) {
  final img = _blank();
  var x = x0;
  var isBar = true;
  for (final u in units) {
    final w = u * module;
    if (isBar) {
      for (var bx = x; bx < x + w; bx++) {
        for (var y = yTop; y <= yBottom; y++) {
          img[y * _side + bx] = 15;
        }
      }
    }
    x += w;
    isBar = !isBar;
  }
  return img;
}

void main() {
  group('decodeCodeFrame decimated pass', () {
    test('a large frame is decoded at 1/2 scale and still reads the QR', () {
      // side > 700 selects factor 2, which walks the strided decimation loop.
      final result = decodeCodeFrame(_qrFrame('decimated-800', side: 800), CodeScanKind.qr);
      expect(result, isNotNull);
      expect(result!.text, 'decimated-800');
      expect(result.format, CodeFormat.qrCode);
    });

    test('a degenerate zero-sized frame decodes to null instead of throwing', () {
      final empty = FrameData(bytes: Uint8List(0), width: 0, height: 0, format: 0);
      expect(decodeCodeFrame(empty, CodeScanKind.postal), isNull);
    });
  });

  group('decodeCodeFrame rotated pass', () {
    test('a vertically-oriented Code 128 is only found by the rotated pass', () {
      final f = _verticalCode128('ROTATED-128');
      final result = decodeCodeFrame(f, CodeScanKind.oneD);
      expect(result, isNotNull);
      expect(result!.text, 'ROTATED-128');
      expect(result.format, CodeFormat.code128);
      // The rotated pass still reports points mapped into the window.
      for (final v in result.windowPoints ?? const <double>[]) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('the rotated pass is skipped for 2D-only kinds', () {
      // A vertical linear code is invisible to the QR kind in both passes.
      expect(decodeCodeFrame(_verticalCode128('IGNORED'), CodeScanKind.qr), isNull);
    });
  });

  group('decodeCodeFrame postal engine', () {
    test('decodes a rendered POSTNET through the full cascade', () {
      final img = _blank();
      _drawBars(img, _encodePostnet('12345').map(_extent2).toList());
      final r = decodeCodeFrame(_frame(img), CodeScanKind.postal);
      expect(r, isNotNull);
      expect(r!.format, CodeFormat.postnet);
      expect(r.text, '12345');
      expect(r.windowPoints, isNull, reason: 'the postal engine reports no key points');
    });

    test('uniform full-height bars fall through rm4scc, postnet and kix', () {
      final img = _blank();
      _drawBars(img, List.generate(16, (_) => _extent4(0)));
      expect(decodeCodeFrame(_frame(img), CodeScanKind.postal), isNull);
    });

    test('a postal frame is not offered to the QR kind', () {
      final img = _blank();
      _drawBars(img, _encodePostnet('12345').map(_extent2).toList());
      expect(decodeCodeFrame(_frame(img), CodeScanKind.qr), isNull);
    });
  });

  group('decodeCodeFrame width engine', () {
    test('decodes a rendered one-track Pharmacode', () {
      final img = _unitsImage(_pharmaOneUnits(1234));
      final r = decodeCodeFrame(_frame(img), CodeScanKind.pharma);
      expect(r, isNotNull);
      expect(r!.format, CodeFormat.pharmacode);
      expect(r.text, '1234');
    });

    test('a scanline that yields no usable units decodes to null', () {
      // A single wide block: one bar run, far below the minimum run count.
      final img = _blank();
      for (var y = 120; y <= 300; y++) {
        for (var x = 40; x < 360; x++) {
          img[y * _side + x] = 15;
        }
      }
      expect(decodeCodeFrame(_frame(img), CodeScanKind.pharma), isNull);
    });
  });

  group('decodeCodeFrame two-track Pharmacode', () {
    test('decodes a rendered two-track symbol after the width engine misses', () {
      final img = _blank();
      _drawBars(img, _pharmaTwoStates(93).map(_extent4).toList());
      final r = decodeCodeFrame(_frame(img), CodeScanKind.pharma);
      expect(r, isNotNull);
      expect(r!.format, CodeFormat.pharmacodeTwoTrack);
      expect(r.text, '93');
    });

    test('the two-track engine is not consulted for the postal kind', () {
      final img = _blank();
      _drawBars(img, _pharmaTwoStates(93).map(_extent4).toList());
      expect(decodeCodeFrame(_frame(img), CodeScanKind.postal)?.format, isNot(CodeFormat.pharmacodeTwoTrack));
    });
  });

  group('mapDecodedPointsToWindow', () {
    test('frameOrientation 180 flips both axes', () {
      final out = mapDecodedPointsToWindow([25, 75], 100, 100, false, frameOrientation: 180);
      expect(out, [closeTo(0.75, 1e-9), closeTo(0.25, 1e-9)]);
    });

    test('frameOrientation 180 composes with the mirror flag', () {
      final out = mapDecodedPointsToWindow([25, 75], 100, 100, false, frameOrientation: 180, mirrored: true);
      expect(out, [closeTo(0.25, 1e-9), closeTo(0.25, 1e-9)]);
    });

    test('an unknown orientation is treated as upright', () {
      final out = mapDecodedPointsToWindow([25, 75], 100, 100, false, frameOrientation: 45);
      expect(out, [closeTo(0.25, 1e-9), closeTo(0.75, 1e-9)]);
    });

    test('a dangling odd coordinate is dropped', () {
      expect(mapDecodedPointsToWindow([50, 50, 10], 100, 100, false), hasLength(2));
    });
  });
}
