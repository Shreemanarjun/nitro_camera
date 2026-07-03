/// Laetus Pharmacode decoders (one-track and two-track).
///
/// Algorithms inverted from Zint `backend/medical.c`:
///
/// * **One-track** (`zint_pharma`): a single integer 3–131070 encoded in
///   "binary plus one" — the encoder repeatedly emits Wide when the value is
///   even (`v = (v - 2) / 2`) or Narrow when odd (`v = (v - 1) / 2`), then
///   prints the emitted digits reversed. Bars are 1 (narrow) or 3 (wide)
///   modules, every inter-bar space is 2 modules. The exact inverse is a
///   left-to-right fold: `v = v * 2 + (wide ? 2 : 1)`.
/// * **Two-track** (`zint_pharma_two` / `pharma_two_calc`): an integer
///   4–64570080 in base-3 digits 1/2/3 (`v % 3 == 1 → 1`, `== 2 → 2`,
///   `== 0 → 3`), printed reversed; digit 1 = ascender-half bar, 2 =
///   descender-half bar, 3 = full bar. Inverse fold: `v = v * 3 + digit`.
///
/// Pharmacode has no checksum or framing, so both decoders demand strict
/// structure and are meant to be enabled only on explicit request
/// (`CodeScanKind.pharma`).
library;

import '../types.dart';

/// Decodes one-track Pharmacode from normalized run widths.
///
/// [units] alternates bar/space run widths in modules (even indices are
/// bars) and starts and ends with a bar. Requires 4–16 bars, bars of width
/// 1 or 3, and every space exactly 2 modules — one-track Pharmacode has no
/// checksum, so anything looser false-positives constantly. The reversed
/// direction is tried when the forward walk fails; note the symbology
/// itself cannot distinguish orientation, so callers should scan it in a
/// known direction.
RawDecode? decodePharmaOneTrack(List<int> units) =>
    _oneTrack(units) ?? _oneTrack(units.reversed.toList());

RawDecode? _oneTrack(List<int> units) {
  // Bars at even indices; a run list ending on a bar has odd length.
  if (units.length.isEven) return null;
  final barCount = (units.length + 1) ~/ 2;
  if (barCount < 4 || barCount > 16) return null;

  var value = 0;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (i.isOdd) {
      // Space: always 2 modules in one-track Pharmacode.
      if (u != 2) return null;
    } else if (u == 1) {
      value = value * 2 + 1; // narrow bar
    } else if (u == 3) {
      value = value * 2 + 2; // wide bar
    } else {
      return null;
    }
  }
  if (value < 3 || value > 131070) return null;
  return RawDecode('$value', CodeFormat.pharmacode);
}

/// Decodes two-track Pharmacode from per-bar 4-state classifications.
///
/// [states] holds one entry per bar: 0 = full, 1 = ascender-only,
/// 2 = descender-only, 3 = tracker. Trackers are invalid in two-track
/// Pharmacode; requires 3–16 bars. When the forward walk fails, the
/// upside-down reading is tried: reversed order with ascenders and
/// descenders swapped (a 180° rotation flips both).
RawDecode? decodePharmaTwoTrack(List<int> states) =>
    _twoTrack(states) ??
    _twoTrack([
      for (final s in states.reversed)
        s == 1
            ? 2
            : s == 2
                ? 1
                : s,
    ]);

RawDecode? _twoTrack(List<int> states) {
  if (states.length < 3 || states.length > 16) return null;
  var value = 0;
  for (final s in states) {
    switch (s) {
      case 0: // full bar → digit 3
        value = value * 3 + 3;
      case 1: // ascender-only → digit 1
        value = value * 3 + 1;
      case 2: // descender-only → digit 2
        value = value * 3 + 2;
      default: // tracker (3) or out-of-contract state
        return null;
    }
  }
  if (value < 4 || value > 64570080) return null;
  return RawDecode('$value', CodeFormat.pharmacodeTwoTrack);
}
