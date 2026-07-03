/// Telepen alpha (full-ASCII) decoder.
///
/// Width-modulated: every glyph is exactly 16 modules of alternating
/// bar/space runs, each run 1 or 3 modules wide. Glyph table and framing
/// transcribed from Zint `backend/telepen.c` (`zint_telepen`):
///
/// * start glyph = `TeleTable[0x5F]` (`'_'`), stop glyph = `TeleTable[0x7A]`
///   (`'z'`);
/// * payload glyphs are the ASCII codes of the message;
/// * check glyph value = `127 - (sum(payload codes) % 127)`, mapped to `0`
///   when the result is `127`.
///
/// Because every glyph occupies exactly 16 modules, the glyph patterns form
/// a prefix code over run sequences, so a left-to-right walk that consumes
/// runs until 16 modules are accumulated segments the symbol unambiguously.
library;

import '../types.dart';

/// Telepen glyph patterns, transcribed from Zint `TeleTable[132][16]`.
///
/// Index = glyph number: 0x00–0x7F are ASCII, 0x80–0x83 are the alternate
/// (compressed-numeric mode) start/stop glyphs. Each string lists the run
/// widths of the glyph in order (bar, space, bar, space, …); widths always
/// sum to 16 modules. Public so tests can build reference symbols from the
/// exact same table.
const List<String> telepenGlyphPatterns = [
  '31313131', '1131313111', '33313111', '1111313131', //          00-03
  '3111313111', '11333131', '13133131', '111111313111', //        04-07
  '31333111', '1131113131', '33113131', '1111333111', //          08-0B
  '3111113131', '1113133111', '1311133111', '111111113131', //    0C-0F
  '3131113111', '11313331', '333331', '111131113111', //          10-13
  '31113331', '1133113111', '1313113111', '1111113331', //        14-17
  '31131331', '113111113111', '3311113111', '1111131331', //      18-1B
  '311111113111', '1113111331', '1311111331', '11111111113111', // 1C-1F
  '31313311', '1131311131', '33311131', '1111313311', //          20-23
  '3111311131', '11333311', '13133311', '111111311131', //        24-27
  '31331131', '1131113311', '33113311', '1111331131', //          28-2B
  '3111113311', '1113131131', '1311131131', '111111113311', //    2C-2F
  '3131111131', '1131131311', '33131311', '111131111131', //      30-33
  '3111131311', '1133111131', '1313111131', '111111131311', //    34-37
  '3113111311', '113111111131', '3311111131', '111113111311', //  38-3B
  '311111111131', '111311111311', '131111111311', '11111111111131', // 3C-3F
  '3131311111', '11313133', '333133', '111131311111', //          40-43
  '31113133', '1133311111', '1313311111', '1111113133', //        44-47
  '313333', '113111311111', '3311311111', '11113333', //          48-4B
  '311111311111', '11131333', '13111333', '11111111311111', //    4C-4F
  '31311133', '1131331111', '33331111', '1111311133', //          50-53
  '3111331111', '11331133', '13131133', '111111331111', //        54-57
  '3113131111', '1131111133', '33111133', '111113131111', //      58-5B
  '3111111133', '111311131111', '131111131111', '111111111133', // 5C-5F (5F = START)
  '31311313', '113131111111', '3331111111', '1111311313', //      60-63
  '311131111111', '11331313', '13131313', '11111131111111', //    64-67
  '3133111111', '1131111313', '33111313', '111133111111', //      68-6B
  '3111111313', '111313111111', '131113111111', '111111111313', // 6C-6F
  '313111111111', '1131131113', '33131113', '11113111111111', //  70-73
  '3111131113', '113311111111', '131311111111', '111111131113', // 74-77
  '3113111113', '11311111111111', '331111111111', '111113111113', // 78-7B (7A = STOP)
  '31111111111111', '111311111113', '131111111113', //            7C-7E
  '1111111111111111', //                                          7F
  '111111113113', '311311111111', //                              80-81 (START 2 / STOP 2)
  '111111311113', '311113111111', //                              82-83 (START 3 / STOP 3)
];

/// Start glyph for Telepen alpha (full ASCII): `'_'` = 0x5F.
const int telepenStartGlyph = 0x5F;

/// Stop glyph for Telepen alpha (full ASCII): `'z'` = 0x7A.
const int telepenStopGlyph = 0x7A;

/// Modules per glyph — every Telepen glyph is exactly 16 modules wide.
const int _glyphModules = 16;

/// Minimum runs: start (12) + shortest glyph (6) + shortest check glyph (6)
/// + stop (12), minus the trailing space trimmed with the quiet zone.
const int _minRuns = 12 + 6 + 6 + 12 - 1;

/// Reverse lookup: run-width pattern → glyph index.
final Map<String, int> _patternToGlyph = {
  for (var i = 0; i < telepenGlyphPatterns.length; i++)
    telepenGlyphPatterns[i]: i,
};

/// Decodes Telepen alpha (full ASCII) from normalized run widths.
///
/// [units] alternates bar/space run widths in modules (even indices are
/// bars) and starts and ends with a bar — the stop glyph's trailing space is
/// assumed trimmed together with the quiet zone. Both scan directions are
/// tried. Returns null unless the start/stop glyphs and the mod-127 check
/// digit all hold and there is at least one payload character.
RawDecode? decodeTelepen(List<int> units) =>
    _decodeDirection(units) ?? _decodeDirection(units.reversed.toList());

RawDecode? _decodeDirection(List<int> units) {
  final glyphs = _segmentGlyphs(units);
  // start + >=1 payload + check + stop
  if (glyphs == null || glyphs.length < 4) return null;
  if (glyphs.first != telepenStartGlyph || glyphs.last != telepenStopGlyph) {
    return null;
  }

  final payload = glyphs.sublist(1, glyphs.length - 2);
  var sum = 0;
  for (final g in payload) {
    if (g > 0x7F) return null; // mode-shift start/stop glyphs mid-symbol
    sum += g;
  }
  var check = 127 - (sum % 127);
  if (check == 127) check = 0;
  if (glyphs[glyphs.length - 2] != check) return null;

  return RawDecode(String.fromCharCodes(payload), CodeFormat.telepen);
}

/// Splits [units] into glyph indices by accumulating runs to 16 modules.
///
/// The final glyph may be short one trailing space run (trimmed quiet zone);
/// its width is reconstructed as the remainder to 16 modules. Returns null
/// on any run width other than 1 or 3, misaligned glyph boundaries, or an
/// unknown pattern.
List<int>? _segmentGlyphs(List<int> units) {
  final n = units.length;
  if (n < _minRuns) return null;
  final glyphs = <int>[];
  var i = 0;
  while (i < n) {
    var width = 0;
    final pattern = StringBuffer();
    var j = i;
    while (j < n && width < _glyphModules) {
      final u = units[j];
      if (u != 1 && u != 3) return null;
      width += u;
      pattern.write(u);
      j++;
    }
    if (width > _glyphModules) return null;
    if (width < _glyphModules) {
      // Ran out of runs: only allowed for the final glyph, whose trailing
      // space was trimmed with the quiet zone. Reconstruct it.
      final missing = _glyphModules - width;
      if (missing != 1 && missing != 3) return null;
      if ((j - i).isEven) return null; // reconstructed run must be a space
      pattern.write(missing);
    }
    final glyph = _patternToGlyph[pattern.toString()];
    if (glyph == null) return null;
    glyphs.add(glyph);
    i = j;
  }
  return glyphs;
}
