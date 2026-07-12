/// MSI / modified Plessey decoder (width-modulated, Luhn mod-10 checked).
///
/// Input is the normalized run-length list: even indices are bars, odd
/// indices are spaces, quiet zones already trimmed. Structure and digit
/// patterns transcribed from Zint `backend/plessey.c` (`MSITable`):
/// start = bar2,space1; each digit = 4 (bar,space) pairs MSB-first with
/// bit 1 = (2,1) and bit 0 = (1,2); stop = bar1,space2,bar1.
library;

import '../types.dart';

/// Decodes an MSI symbol from normalized run widths. Tries the reversed
/// run list too (upside-down scan). Returns null unless the frame structure
/// holds and the trailing Luhn mod-10 check digit validates.
RawDecode? decodeMsi(List<int> units) => _decode(units) ?? _decode(units.reversed.toList());

RawDecode? _decode(List<int> units) {
  final n = units.length;
  // Frame: start(2) + 8·digits + stop(3); at least 4 digits incl. the check.
  if (n < 2 + 8 * 4 + 3 || (n - 5) % 8 != 0) return null;
  if (units[0] != 2 || units[1] != 1) return null;
  if (units[n - 3] != 1 || units[n - 2] != 2 || units[n - 1] != 1) return null;

  final digits = <int>[];
  for (var i = 2; i + 8 <= n - 3; i += 8) {
    var value = 0;
    for (var b = 0; b < 4; b++) {
      final bar = units[i + 2 * b];
      final space = units[i + 2 * b + 1];
      if (bar == 2 && space == 1) {
        value = (value << 1) | 1;
      } else if (bar == 1 && space == 2) {
        value <<= 1;
      } else {
        return null;
      }
    }
    if (value > 9) return null; // 4-bit values 10–15 are not MSI digits.
    digits.add(value);
  }
  if (digits.length < 4) return null;

  final check = digits.removeLast();
  if (_luhnCheckDigit(digits) != check) return null;
  return RawDecode(digits.join(), CodeFormat.msi);
}

/// Luhn mod-10 check digit: starting from the rightmost payload digit,
/// double every other digit, sum the digits of the products (d − 9 for
/// two-digit products), and return the value that makes the total ≡ 0 mod 10.
int _luhnCheckDigit(List<int> payload) {
  var sum = 0;
  var doubled = true;
  for (var i = payload.length - 1; i >= 0; i--) {
    var d = payload[i];
    if (doubled) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    doubled = !doubled;
  }
  return (10 - sum % 10) % 10;
}
