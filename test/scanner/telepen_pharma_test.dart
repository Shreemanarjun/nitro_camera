import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/src/scanner/decoders/pharmacode.dart';
import 'package:nitro_camera/src/scanner/decoders/telepen.dart';
import 'package:nitro_camera/src/scanner/types.dart';

// ─── Reference encoders (same Zint algorithms as the decoders) ──────────────

/// Telepen alpha, per Zint `zint_telepen`: start `_` (0x5F) + payload glyphs
/// + check glyph (127 - sum % 127, 127 → 0) + stop `z` (0x7A). Returns run
/// widths with the stop glyph's trailing space trimmed (quiet zone).
List<int> telepenUnits(String text, {int? forcedCheck}) {
  var check = 127 - (text.codeUnits.fold<int>(0, (a, b) => a + b) % 127);
  if (check == 127) check = 0;
  final runs = StringBuffer(telepenGlyphPatterns[0x5F]);
  for (final c in text.codeUnits) {
    runs.write(telepenGlyphPatterns[c]);
  }
  runs
    ..write(telepenGlyphPatterns[forcedCheck ?? check])
    ..write(telepenGlyphPatterns[0x7A]);
  final units = runs.toString().split('').map(int.parse).toList();
  return units.sublist(0, units.length - 1); // trailing space → quiet zone
}

/// One-track Pharmacode, per Zint `zint_pharma`: emit W on even
/// (v = (v-2)/2), N on odd (v = (v-1)/2); print reversed; bar W=3 / N=1,
/// spaces 2, final space chopped.
List<int> pharmaOneUnits(int value) {
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
  return units.sublist(0, units.length - 1); // chop final space
}

/// Two-track Pharmacode, per Zint `pharma_two_calc`: base-3 digits
/// (0 → '3', 1 → '1', 2 → '2'), printed reversed. Returns 4-state bar list:
/// digit 1 → ascender (1), 2 → descender (2), 3 → full (0).
List<int> pharmaTwoStates(int value) {
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

/// 180° rotation of a two-track state list: reversed order, ascender (1)
/// and descender (2) swapped, full (0) unchanged.
List<int> flipTwoTrack(List<int> states) => [
  for (final s in states.reversed)
    s == 1
        ? 2
        : s == 2
        ? 1
        : s,
];

void main() {
  group('Telepen glyph table', () {
    test('has 132 entries of 16 modules each, all unique', () {
      expect(telepenGlyphPatterns, hasLength(132));
      for (final p in telepenGlyphPatterns) {
        expect(p.length.isEven, isTrue, reason: 'ends on a space: $p');
        var sum = 0;
        for (final c in p.split('')) {
          expect(c == '1' || c == '3', isTrue, reason: 'run widths 1/3: $p');
          sum += int.parse(c);
        }
        expect(sum, 16, reason: 'glyph must span 16 modules: $p');
      }
      expect(telepenGlyphPatterns.toSet(), hasLength(132));
    });

    test('spot checks against Zint TeleTable', () {
      expect(telepenGlyphPatterns[0x00], '31313131');
      expect(telepenGlyphPatterns[0x12], '333331');
      expect(telepenGlyphPatterns[0x42], '333133'); // 'B'
      expect(telepenGlyphPatterns[0x48], '313333'); // 'H'
      expect(telepenGlyphPatterns[0x5F], '111111111133'); // START '_'
      expect(telepenGlyphPatterns[0x66], '13131313'); // 'f'
      expect(telepenGlyphPatterns[0x7A], '331111111111'); // STOP 'z'
      expect(telepenGlyphPatterns[0x7F], '1111111111111111'); // DEL
      expect(telepenGlyphPatterns[0x80], '111111113113'); // START 2
      expect(telepenGlyphPatterns[0x83], '311113111111'); // STOP 3
    });

    test('patterns form a prefix code over run sequences', () {
      // Fixed 16-module glyph width implies this; verify explicitly since
      // the decoder's greedy segmentation depends on it.
      for (var i = 0; i < telepenGlyphPatterns.length; i++) {
        for (var j = 0; j < telepenGlyphPatterns.length; j++) {
          if (i == j) continue;
          expect(
            telepenGlyphPatterns[j].startsWith(telepenGlyphPatterns[i]),
            isFalse,
            reason: 'glyph $i is a run-prefix of glyph $j',
          );
        }
      }
    });
  });

  group('decodeTelepen', () {
    test('round-trips "ABC123"', () {
      final r = decodeTelepen(telepenUnits('ABC123'));
      expect(r, isNotNull);
      expect(r!.text, 'ABC123');
      expect(r.format, CodeFormat.telepen);
      expect(r.isGs1, isFalse);
    });

    test('round-trips a single-character payload', () {
      final r = decodeTelepen(telepenUnits('A'));
      expect(r?.text, 'A');
      expect(r?.format, CodeFormat.telepen);
    });

    test('round-trips control characters and check digit 0 wrap', () {
      // DEL (127): sum % 127 == 0 → check 127 → wraps to glyph 0.
      final del = String.fromCharCode(127);
      expect(decodeTelepen(telepenUnits(del))?.text, del);
      const mixed = 'Hi\x10 42!'; // includes DLE
      expect(decodeTelepen(telepenUnits(mixed))?.text, mixed);
    });

    test('decodes reversed (upside-down) scans', () {
      for (final text in ['ABC123', 'A', 'Telepen-OK']) {
        final reversed = telepenUnits(text).reversed.toList();
        expect(decodeTelepen(reversed)?.text, text);
      }
    });

    test('rejects a wrong check digit', () {
      // 'ABC123' has check 33; force a different (valid-glyph) check.
      expect(decodeTelepen(telepenUnits('ABC123', forcedCheck: 34)), isNull);
    });

    test('rejects an empty payload (start + check + stop only)', () {
      expect(decodeTelepen(telepenUnits('')), isNull);
    });

    test('rejects truncated and corrupted symbols', () {
      final units = telepenUnits('ABC123');
      expect(decodeTelepen(units.sublist(0, units.length - 4)), isNull);
      expect(decodeTelepen(units.sublist(2)), isNull);
      final badWidth = [...units]..[8] = 2; // width neither 1 nor 3
      expect(decodeTelepen(badWidth), isNull);
    });

    test('rejects random run lists', () {
      final rng = Random(1234);
      for (var i = 0; i < 300; i++) {
        final n = 35 + rng.nextInt(60) * 2; // odd length, ends on a bar
        final units = [for (var j = 0; j < n; j++) rng.nextBool() ? 1 : 3];
        expect(decodeTelepen(units), isNull);
      }
    });
  });

  group('decodePharmaOneTrack', () {
    test('round-trips known values', () {
      for (final v in [15, 90, 12345, 131070]) {
        final r = decodePharmaOneTrack(pharmaOneUnits(v));
        expect(r?.text, '$v');
        expect(r?.format, CodeFormat.pharmacode);
      }
    });

    test('round-trips a palindromic symbol scanned upside-down', () {
      // 21 → bars N W W N: symmetric, so orientation cannot matter.
      final reversed = pharmaOneUnits(21).reversed.toList();
      expect(decodePharmaOneTrack(reversed)?.text, '21');
    });

    test('reversed non-palindromic input decodes to the mirrored value', () {
      // One-track Pharmacode has no framing: a flipped symbol is itself a
      // valid symbol for a different number. Document the inherent
      // ambiguity: 90 = N W W N W W reads backwards as W W N W W N = 117.
      final reversed = pharmaOneUnits(90).reversed.toList();
      expect(decodePharmaOneTrack(reversed)?.text, '117');
    });

    test('requires at least 4 bars', () {
      expect(pharmaOneUnits(7), hasLength(5)); // 3 bars
      expect(decodePharmaOneTrack(pharmaOneUnits(7)), isNull);
      expect(decodePharmaOneTrack(pharmaOneUnits(15)), isNotNull); // 4 bars
    });

    test('rejects values above 131070 (more than 16 bars)', () {
      final units = pharmaOneUnits(131071); // 17 bars
      expect(decodePharmaOneTrack(units), isNull);
    });

    test('rejects malformed structure', () {
      final good = pharmaOneUnits(12345);
      // A space that is not 2 modules.
      expect(decodePharmaOneTrack([...good]..[1] = 1), isNull);
      expect(decodePharmaOneTrack([...good]..[3] = 3), isNull);
      // A bar that is neither narrow (1) nor wide (3).
      expect(decodePharmaOneTrack([...good]..[0] = 2), isNull);
      // Even-length run list (ends on a space).
      expect(decodePharmaOneTrack([...good, 2]), isNull);
      expect(decodePharmaOneTrack(const []), isNull);
    });
  });

  group('decodePharmaTwoTrack', () {
    test('round-trips known values', () {
      for (final v in [40, 1234567, 21523360, 64570080]) {
        final r = decodePharmaTwoTrack(pharmaTwoStates(v));
        expect(r?.text, '$v');
        expect(r?.format, CodeFormat.pharmacodeTwoTrack);
      }
    });

    test('round-trips a flip-symmetric symbol scanned upside-down', () {
      // 20 → digits 1,3,2 → states [asc, full, desc]: its own 180° rotation.
      final flipped = flipTwoTrack(pharmaTwoStates(20));
      expect(decodePharmaTwoTrack(flipped)?.text, '20');
    });

    test('flipped non-symmetric input decodes to the mirrored value', () {
      // Like one-track, two-track has no framing; a flipped symbol is a
      // valid symbol for another number. 40 = [1,1,1,1] all ascenders;
      // flipped = all descenders = digits 2,2,2,2 = 80.
      final flipped = flipTwoTrack(pharmaTwoStates(40));
      expect(decodePharmaTwoTrack(flipped)?.text, '80');
    });

    test('requires at least 3 bars', () {
      expect(pharmaTwoStates(4), hasLength(2));
      expect(decodePharmaTwoTrack(pharmaTwoStates(4)), isNull);
      expect(decodePharmaTwoTrack(pharmaTwoStates(13)), isNotNull); // 3 bars
    });

    test('rejects values above 64570080 (more than 16 bars)', () {
      expect(decodePharmaTwoTrack(pharmaTwoStates(64570081)), isNull);
    });

    test('rejects trackers and out-of-contract states', () {
      final good = pharmaTwoStates(1234567);
      expect(decodePharmaTwoTrack([...good]..[2] = 3), isNull); // tracker
      expect(decodePharmaTwoTrack([...good]..[0] = 4), isNull);
      expect(decodePharmaTwoTrack([...good]..[1] = -1), isNull);
      expect(decodePharmaTwoTrack(const []), isNull);
    });

    test('rejects random state lists containing trackers', () {
      final rng = Random(99);
      for (var i = 0; i < 200; i++) {
        final n = 3 + rng.nextInt(14);
        final states = [for (var j = 0; j < n; j++) rng.nextInt(3)];
        states[rng.nextInt(n)] = 3; // at least one tracker
        expect(decodePharmaTwoTrack(states), isNull);
      }
    });
  });
}
