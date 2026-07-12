/// Royal Mail 4-State (RM4SCC, checksummed) and Dutch TNT KIX decoder.
///
/// Input is the 4-state classification of the extracted bars
/// (`classify4State`): 0 = full, 1 = ascender, 2 = descender, 3 = tracker.
/// Tables transcribed from Zint `backend/postal.c`.
library;

import '../types.dart';

/// RM4SCC / KIX character set (index = symbol value).
const String _charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// 4-bar patterns per symbol value: 0 full, 1 ascender, 2 descender,
/// 3 tracker.
const List<List<int>> _table = [
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

/// Checksum weights (top, bottom) per symbol value.
const List<List<int>> _checkTopBottom = [
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

final Map<String, int> _lookup = {
  for (var i = 0; i < _table.length; i++) _table[i].join(): i,
};

/// Decodes RM4SCC: start(ascender) + 4-bar chars + check char + stop(full).
RawDecode? decodeRm4scc(List<int> states) {
  final n = states.length;
  if (n < 1 + 8 + 1) return null;
  if (states.first != 1 || states.last != 0) return null;
  final body = states.sublist(1, n - 1);
  if (body.length % 4 != 0) return null;

  final values = <int>[];
  for (var i = 0; i + 4 <= body.length; i += 4) {
    final v = _lookup[body.sublist(i, i + 4).join()];
    if (v == null) return null;
    values.add(v);
  }
  if (values.length < 2) return null;

  // Verify the trailing check character (Zint rm4scc_enc).
  final payload = values.sublist(0, values.length - 1);
  var topSum = 0, bottomSum = 0;
  for (final v in payload) {
    topSum += _checkTopBottom[v][0];
    bottomSum += _checkTopBottom[v][1];
  }
  var row = (topSum % 6) - 1;
  var column = (bottomSum % 6) - 1;
  if (row == -1) row = 5;
  if (column == -1) column = 5;
  if (values.last != 6 * row + column) return null;

  return RawDecode(
    payload.map((v) => _charset[v]).join(),
    CodeFormat.rm4scc,
  );
}

/// Decodes KIX: bare 4-bar chars, no start/stop/checksum. Requires ≥5 chars
/// of fully-valid groups to keep the false-positive rate down.
RawDecode? decodeKix(List<int> states) {
  if (states.length % 4 != 0 || states.length < 20) return null;
  final chars = <String>[];
  for (var i = 0; i + 4 <= states.length; i += 4) {
    final v = _lookup[states.sublist(i, i + 4).join()];
    if (v == null) return null;
    chars.add(_charset[v]);
  }
  return RawDecode(chars.join(), CodeFormat.kix);
}
