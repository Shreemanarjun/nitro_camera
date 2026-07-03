/// Code 11 decoder (width-modulated, C and optional K mod-11 checks).
///
/// Input is the normalized run-length list: even indices are bars, odd
/// indices are spaces, quiet zones already trimmed. Character patterns
/// transcribed from Zint `backend/code11.c` (`C11Table`): each entry is
/// bar,space,bar,space,bar plus the 1-unit inter-character gap. Start is
/// `112211` (with trailing gap); stop is `11221` (no gap).
library;

import '../types.dart';

/// Character patterns for `0`–`9` and `-`, six runs each (five elements plus
/// the trailing 1-unit gap).
const List<String> _c11Table = [
  '111121', // 0
  '211121', // 1
  '121121', // 2
  '221111', // 3
  '112121', // 4
  '212111', // 5
  '122111', // 6
  '111221', // 7
  '211211', // 8
  '211111', // 9
  '112111', // -
];

const String _c11Chars = '0123456789-';

/// Decodes a Code 11 symbol from normalized run widths. Tries the reversed
/// run list too (upside-down scan). Returns null unless the frame structure
/// holds and the C (and, when present, K) mod-11 check characters validate.
RawDecode? decodeCode11(List<int> units) =>
    _decode(units) ?? _decode(units.reversed.toList());

RawDecode? _decode(List<int> units) {
  final n = units.length;
  // Frame: start(6) + 6·chars + stop(5); >= 3 payload chars + the C check.
  if (n < 6 + 6 * 4 + 5 || (n - 11) % 6 != 0) return null;
  const start = [1, 1, 2, 2, 1, 1];
  for (var i = 0; i < 6; i++) {
    if (units[i] != start[i]) return null;
  }
  const stop = [1, 1, 2, 2, 1];
  for (var i = 0; i < 5; i++) {
    if (units[n - 5 + i] != stop[i]) return null;
  }

  final values = <int>[];
  for (var i = 6; i + 6 <= n - 5; i += 6) {
    final v = _c11Table.indexOf(units.sublist(i, i + 6).join());
    if (v < 0) return null;
    values.add(v);
  }

  // Interpretation 1: the last character is the C check.
  if (values.length >= 4) {
    final payload = values.sublist(0, values.length - 1);
    if (_mod11(payload, 10) == values.last) {
      return RawDecode(_toText(payload), CodeFormat.code11);
    }
  }
  // Interpretation 2: the last two characters are C then K (K is appended
  // when the message is 10+ characters long).
  if (values.length >= 5) {
    final withC = values.sublist(0, values.length - 1);
    final payload = values.sublist(0, values.length - 2);
    if (_mod11(withC, 9) == values.last && _mod11(payload, 10) == withC.last) {
      return RawDecode(_toText(payload), CodeFormat.code11);
    }
  }
  return null;
}

String _toText(List<int> values) => values.map((v) => _c11Chars[v]).join();

/// Weighted mod-11 checksum: weights run 1,2,…,[maxWeight] from the
/// rightmost character leftward, then cycle back to 1 (C uses 10, K uses 9).
int _mod11(List<int> values, int maxWeight) {
  var sum = 0;
  var weight = 1;
  for (var i = values.length - 1; i >= 0; i--) {
    sum += values[i] * weight;
    if (++weight > maxWeight) weight = 1;
  }
  return sum % 11;
}
