import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/src/scanner/engine/binarizer.dart';
import 'package:nitro_camera/src/scanner/engine/scanline.dart';

/// Builds a [GrayWindow] whose every row is [pattern] (`#` = dark, `.` = light).
///
/// The plane is deliberately larger than the window and uses a padded stride
/// plus a non-zero origin, so any stride/offset arithmetic bug shows up as a
/// wrong run list rather than passing by accident. Pixel values are the
/// extremes 0/255, which pins Otsu's threshold and makes binarization exact.
GrayWindow _window(String pattern, {int height = 8, int left = 3, int top = 2, int strideExtra = 5}) {
  final w = pattern.length;
  final stride = left + w + strideExtra;
  final plane = Uint8List((top + height + 2) * stride);
  // Fill the whole plane light so out-of-window pixels can never read dark.
  plane.fillRange(0, plane.length, 255);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < w; x++) {
      plane[(top + y) * stride + left + x] = pattern[x] == '#' ? 0 : 255;
    }
  }
  return GrayWindow(plane, stride: stride, left: left, top: top, width: w, height: height);
}

void main() {
  group('extractScanlineRuns', () {
    test('trims the leading quiet zone and the trailing space run', () {
      // ..##.###.#.  ->  bar 2, space 1, bar 3, space 1, bar 1
      final runs = extractScanlineRuns(_window('..##.###.#.'), minRuns: 1, rowFractions: const [0.5]);

      expect(runs, [
        [2, 1, 3, 1, 1],
      ]);
    });

    test('a row that ends on a bar keeps its final run', () {
      final runs = extractScanlineRuns(_window('..##.#'), minRuns: 1, rowFractions: const [0.5]);

      expect(runs, [
        [2, 1, 1],
      ]);
      expect(runs.single.length.isOdd, isTrue, reason: 'runs must start and end with a bar');
    });

    test('an alternating row yields unit runs for every element', () {
      final runs = extractScanlineRuns(_window('#.#.#.#.#'), rowFractions: const [0.5]);

      expect(runs, [
        [1, 1, 1, 1, 1, 1, 1, 1, 1],
      ]);
    });

    test('a single transition (one bar, one space) is trimmed back to one bar', () {
      final runs = extractScanlineRuns(_window('###...'), minRuns: 1, rowFractions: const [0.5]);

      expect(runs, [
        [3],
      ]);
    });

    test('a uniformly dark row is one bar run of the full width', () {
      final runs = extractScanlineRuns(_window('####'), minRuns: 1, rowFractions: const [0.5]);

      expect(runs, [
        [4],
      ]);
    });

    test('a uniformly light row produces no scanline at all', () {
      expect(
        extractScanlineRuns(_window('.....'), minRuns: 1, rowFractions: const [0.5]),
        isEmpty,
      );
    });

    test('a zero-width window produces no scanline', () {
      final plane = Uint8List(16)..fillRange(0, 16, 255);
      final win = GrayWindow(plane, stride: 4, left: 0, top: 0, width: 0, height: 1);

      expect(extractScanlineRuns(win, minRuns: 1, rowFractions: const [0.5]), isEmpty);
    });

    test('rows with fewer than minRuns runs are dropped', () {
      final win = _window('..##.###.#.'); // 5 runs

      expect(extractScanlineRuns(win, rowFractions: const [0.5]), isEmpty, reason: 'default minRuns is 7');
      expect(extractScanlineRuns(win, minRuns: 6, rowFractions: const [0.5]), isEmpty);
      expect(extractScanlineRuns(win, minRuns: 5, rowFractions: const [0.5]), hasLength(1));
    });

    test('one run list is produced per requested row fraction', () {
      final runs = extractScanlineRuns(_window('#.#.#.#.#', height: 20));

      // Five default fractions, every row identical.
      expect(runs, hasLength(5));
      expect(runs.every((r) => r.length == 9), isTrue);
    });

    test('only the rows that actually carry a code contribute', () {
      // Rows 0..3 blank, rows 4..7 hold the pattern: the 0.26 fraction lands on
      // row 2 (blank) and is dropped; 0.5 / 0.38 / 0.62 / 0.74 land on 4/3/5/6.
      const pattern = '#.#.#.#.#';
      const height = 8;
      const left = 1, top = 0, stride = 16;
      final plane = Uint8List(height * stride)..fillRange(0, height * stride, 255);
      for (var y = 4; y < height; y++) {
        for (var x = 0; x < pattern.length; x++) {
          plane[y * stride + left + x] = pattern[x] == '#' ? 0 : 255;
        }
      }
      final win = GrayWindow(plane, stride: stride, left: left, top: top, width: pattern.length, height: height);

      // y = round(8*f): 0.5->4, 0.38->3, 0.62->5, 0.26->2, 0.74->6.
      final runs = extractScanlineRuns(win);
      expect(runs, hasLength(3), reason: 'rows 3 and 2 are blank');
    });

    test('the row index is clamped into the window', () {
      // height 1: fraction 0.74 rounds to 1, which must clamp back to row 0.
      final runs = extractScanlineRuns(
        _window('#.#.#', height: 1),
        minRuns: 1,
        rowFractions: const [0.74, 0.0],
      );

      expect(runs, [
        [1, 1, 1, 1, 1],
        [1, 1, 1, 1, 1],
      ]);
    });

    test('an empty fraction list scans nothing', () {
      expect(extractScanlineRuns(_window('#.#.#.#.#'), rowFractions: const []), isEmpty);
    });
  });

  group('runsToUnits', () {
    test('normalizes pixel widths against the narrowest element', () {
      expect(runsToUnits([2, 2, 4, 2, 6, 2]), [1, 1, 2, 1, 3, 1]);
    });

    test('already-unit runs pass through unchanged', () {
      expect(runsToUnits([1, 1, 1, 1]), [1, 1, 1, 1]);
    });

    test('the module estimate averages the narrow elements, absorbing jitter', () {
      // Narrow elements 9/10/11 average to 10, so 20 resolves to 2 units even
      // though 20 / 9 would round to 2.2.
      expect(runsToUnits([9, 10, 11, 20, 10]), [1, 1, 1, 2, 1]);
    });

    test('returns null when a run exceeds maxUnit', () {
      expect(runsToUnits([2, 2, 12]), isNull, reason: '6 units > default maxUnit 4');
      expect(runsToUnits([2, 2, 12], maxUnit: 6), [1, 1, 6]);
    });

    test('maxUnit is inclusive at the boundary', () {
      expect(runsToUnits([2, 8], maxUnit: 4), [1, 4]);
      expect(runsToUnits([2, 10], maxUnit: 4), isNull);
    });

    test('an empty run list has no module estimate', () {
      expect(runsToUnits([]), isNull);
    });

    test('a non-positive run is rejected instead of dividing by zero', () {
      expect(runsToUnits([0, 4, 4]), isNull);
      expect(runsToUnits([-3, 4]), isNull);
    });

    test('every unit is at least 1, never 0', () {
      // A wide module with one sub-module speck must not round down to 0.
      final units = runsToUnits([10, 10, 10, 4]);
      expect(units, isNotNull);
      expect(units!.every((u) => u >= 1), isTrue);
    });

    test('scanline runs feed straight into unit normalization', () {
      final runs = extractScanlineRuns(
        _window('..##.####..##.#'),
        minRuns: 1,
        rowFractions: const [0.5],
      ).single;

      expect(runs, [2, 1, 4, 2, 2, 1, 1]);
      expect(runsToUnits(runs), [2, 1, 4, 2, 2, 1, 1]);
    });
  });
}
