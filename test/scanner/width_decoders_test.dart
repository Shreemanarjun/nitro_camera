import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/src/scanner/decoders/code11.dart';
import 'package:nitro_camera/src/scanner/decoders/industrial_2of5.dart';
import 'package:nitro_camera/src/scanner/decoders/msi.dart';
import 'package:nitro_camera/src/scanner/types.dart';

// ─── Reference encoders (same Zint tables as the decoders) ─────────────────

/// MSI: start (2,1) + 4 bit pairs per digit MSB-first + stop (1,2,1).
List<int> msiUnits(String digitsWithCheck) {
  final u = <int>[2, 1];
  for (final c in digitsWithCheck.split('')) {
    final d = int.parse(c);
    for (var b = 3; b >= 0; b--) {
      if ((d >> b) & 1 == 1) {
        u.addAll([2, 1]);
      } else {
        u.addAll([1, 2]);
      }
    }
  }
  return u..addAll([1, 2, 1]);
}

/// Luhn mod-10 check digit over [payload] (rightmost digit doubled first).
int luhn(String payload) {
  var sum = 0;
  var doubled = true;
  for (var i = payload.length - 1; i >= 0; i--) {
    var d = int.parse(payload[i]);
    if (doubled) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    doubled = !doubled;
  }
  return (10 - sum % 10) % 10;
}

const c11Table = [
  '111121', '211121', '121121', '221111', '112121', '212111', //
  '122111', '111221', '211211', '211111', '112111',
];
const c11Chars = '0123456789-';

/// Code 11: start 112211 + 6-run chars (incl. gap) + stop 11221 (no gap).
List<int> code11Units(String charsWithChecks) {
  final u = <int>[1, 1, 2, 2, 1, 1];
  for (final ch in charsWithChecks.split('')) {
    u.addAll(c11Table[c11Chars.indexOf(ch)].split('').map(int.parse));
  }
  return u..addAll([1, 1, 2, 2, 1]);
}

/// Code 11 weighted mod-11 checksum (weights 1..maxWeight from the right).
int c11Check(String chars, int maxWeight) {
  var sum = 0;
  var weight = 1;
  for (var i = chars.length - 1; i >= 0; i--) {
    sum += c11Chars.indexOf(chars[i]) * weight;
    if (++weight > maxWeight) weight = 1;
  }
  return sum % 11;
}

const ind25Bars = [
  '11331', '31113', '13113', '33111', '11313', //
  '31311', '13311', '11133', '31131', '13131',
];

/// Industrial 2-of-5: start 313111 + 5 (bar, narrow space) per digit +
/// stop 31113. All spaces narrow; [wide] is the wide-bar width.
List<int> ind25Units(String digits, {int wide = 3}) {
  final u = <int>[wide, 1, wide, 1, 1, 1];
  for (final c in digits.split('')) {
    for (final w in ind25Bars[int.parse(c)].split('')) {
      u.addAll([w == '3' ? wide : 1, 1]);
    }
  }
  return u..addAll([wide, 1, 1, 1, wide]);
}

void main() {
  group('MSI', () {
    final units = msiUnits('1234${luhn('1234')}');

    test('round-trips 1234 with Luhn check', () {
      final r = decodeMsi(units);
      expect(r, isNotNull);
      expect(r!.text, '1234');
      expect(r.format, CodeFormat.msi);
    });

    test('decodes reversed (upside-down) runs', () {
      final r = decodeMsi(units.reversed.toList());
      expect(r?.text, '1234');
      expect(r?.format, CodeFormat.msi);
    });

    test('rejects a wrong check digit', () {
      final bad = (luhn('1234') + 1) % 10;
      expect(decodeMsi(msiUnits('1234$bad')), isNull);
    });

    test('rejects short / malformed input', () {
      expect(decodeMsi(const []), isNull);
      expect(decodeMsi(const [2, 1, 1, 2, 1]), isNull);
      expect(decodeMsi(msiUnits('18')), isNull); // < 4 digits total
    });
  });

  group('Code 11', () {
    test('round-trips 123-45 with C check', () {
      final c = c11Chars[c11Check('123-45', 10)];
      final r = decodeCode11(code11Units('123-45$c'));
      expect(r, isNotNull);
      expect(r!.text, '123-45');
      expect(r.format, CodeFormat.code11);
    });

    test('round-trips a 10-char message with C and K checks', () {
      const payload = '0123456789';
      final c = c11Chars[c11Check(payload, 10)];
      final k = c11Chars[c11Check('$payload$c', 9)];
      final r = decodeCode11(code11Units('$payload$c$k'));
      expect(r?.text, payload);
      expect(r?.format, CodeFormat.code11);
    });

    test('decodes reversed (upside-down) runs', () {
      final c = c11Chars[c11Check('123-45', 10)];
      final r = decodeCode11(code11Units('123-45$c').reversed.toList());
      expect(r?.text, '123-45');
    });

    test('rejects a wrong C check character', () {
      final bad = c11Chars[(c11Check('123-45', 10) + 1) % 11];
      expect(decodeCode11(code11Units('123-45$bad')), isNull);
    });

    test('rejects short / malformed input', () {
      expect(decodeCode11(const []), isNull);
      final c = c11Chars[c11Check('12', 10)];
      expect(decodeCode11(code11Units('12$c')), isNull); // < 3 payload chars
    });
  });

  group('Industrial 2-of-5', () {
    test('round-trips 1234', () {
      final r = decodeIndustrial2of5(ind25Units('1234'));
      expect(r, isNotNull);
      expect(r!.text, '1234');
      expect(r.format, CodeFormat.industrial2of5);
    });

    test('decodes reversed (upside-down) runs', () {
      final r = decodeIndustrial2of5(ind25Units('90876').reversed.toList());
      expect(r?.text, '90876');
      expect(r?.format, CodeFormat.industrial2of5);
    });

    test('accepts degraded wide bars of 2 units', () {
      final r = decodeIndustrial2of5(ind25Units('5081', wide: 2));
      expect(r?.text, '5081');
    });

    test('rejects a wide space', () {
      final units = ind25Units('1234');
      units[7] = 3; // widen a space inside the first digit
      expect(decodeIndustrial2of5(units), isNull);
    });

    test('rejects short / malformed input', () {
      expect(decodeIndustrial2of5(const []), isNull);
      expect(decodeIndustrial2of5(ind25Units('123')), isNull); // < 4 digits
    });
  });

  group('noise rejection', () {
    test('random unit lists never decode', () {
      final rng = Random(42);
      for (var trial = 0; trial < 200; trial++) {
        // Odd lengths so the list starts and ends with a bar, like real input.
        final len = 25 + 2 * rng.nextInt(40);
        final units = List<int>.generate(len, (_) => 1 + rng.nextInt(3));
        expect(decodeMsi(units), isNull, reason: 'MSI trial $trial');
        expect(decodeCode11(units), isNull, reason: 'Code11 trial $trial');
        expect(decodeIndustrial2of5(units), isNull,
            reason: '2of5 trial $trial');
      }
    });
  });
}
