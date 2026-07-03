/// Standard / Industrial 2-of-5 decoder (width-modulated, data in bars only).
///
/// Input is the normalized run-length list: even indices are bars, odd
/// indices are spaces, quiet zones already trimmed. All spaces are narrow;
/// only the bars carry data (two wide out of five). Digit patterns
/// transcribed from Zint `backend/2of5.c` (`C25IndustTable`, bar elements).
/// Start bars = wide,wide,narrow; stop bars = wide,narrow,wide.
///
/// The symbology has no checksum, so acceptance additionally requires at
/// least 4 digits and every space narrow to keep false positives down.
library;

import '../types.dart';

/// Bar-width patterns per digit (five bars, narrow = 1, wide = 3).
const List<String> _digitBars = [
  '11331', // 0
  '31113', // 1
  '13113', // 2
  '33111', // 3
  '11313', // 4
  '31311', // 5
  '13311', // 6
  '11133', // 7
  '31131', // 8
  '13131', // 9
];

/// Decodes an Industrial 2-of-5 symbol from normalized run widths. Tries the
/// reversed run list too (upside-down scan). Wide bars nominally normalize
/// to 3 units but degrade to 2 with poor module estimates, so any bar of
/// 2+ units counts as wide. Returns null unless the frame structure holds,
/// every space is narrow and there are at least 4 digits.
RawDecode? decodeIndustrial2of5(List<int> units) =>
    _decode(units) ?? _decode(units.reversed.toList());

RawDecode? _decode(List<int> units) {
  final n = units.length;
  // Frame: start(6) + 10·digits + stop(5); at least 4 digits.
  if (n < 6 + 10 * 4 + 5 || (n - 11) % 10 != 0) return null;

  // Every space (odd index) must be narrow.
  for (var i = 1; i < n; i += 2) {
    if (units[i] > 1) return null;
  }

  // Start bars: wide, wide, narrow. Stop bars: wide, narrow, wide.
  if (!_wide(units[0]) || !_wide(units[2]) || !_narrow(units[4])) return null;
  if (!_wide(units[n - 5]) || !_narrow(units[n - 3]) || !_wide(units[n - 1])) {
    return null;
  }

  final digits = StringBuffer();
  for (var i = 6; i + 10 <= n - 5; i += 10) {
    final bars = StringBuffer();
    for (var b = 0; b < 5; b++) {
      final u = units[i + 2 * b];
      if (_narrow(u)) {
        bars.write('1');
      } else if (_wide(u)) {
        bars.write('3');
      } else {
        return null;
      }
    }
    final d = _digitBars.indexOf(bars.toString());
    if (d < 0) return null;
    digits.write(d);
  }
  if (digits.length < 4) return null;
  return RawDecode(digits.toString(), CodeFormat.industrial2of5);
}

bool _narrow(int u) => u == 1;

bool _wide(int u) => u >= 2;
