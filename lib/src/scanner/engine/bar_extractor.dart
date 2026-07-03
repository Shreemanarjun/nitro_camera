import 'binarizer.dart';

/// A segmented vertical bar: inclusive column range + vertical dark extent,
/// with y coordinates relative to the containing band's top.
class Bar {
  final int x0, x1;
  final int yMin, yMax;
  const Bar(this.x0, this.x1, this.yMin, this.yMax);
}

/// Extracts candidate bars for height-modulated symbologies (postal codes,
/// two-track Pharmacode) from a [GrayWindow].
///
/// Finds horizontal bands of content via a row-darkness profile, segments
/// bars from the column profile of each band (largest first), and returns
/// the bars of the first band with a plausible bar count. Codes must be
/// roughly horizontal.
List<Bar>? extractBars(GrayWindow win, {int minBars = 12}) {
  final w = win.width, h = win.height;
  if (w < 20 || h < 10) return null;

  // Row profile → candidate content bands.
  final rowDark = List<int>.filled(h, 0);
  for (var y = 0; y < h; y++) {
    var c = 0;
    for (var x = 0; x < w; x++) {
      if (win.dark(x, y)) c++;
    }
    rowDark[y] = c;
  }
  final rowThr = (w * 0.02).clamp(2, 1 << 30).toInt();

  final bands = <List<int>>[];
  var runStart = -1;
  for (var y = 0; y <= h; y++) {
    final on = y < h && rowDark[y] >= rowThr;
    if (on && runStart < 0) runStart = y;
    if (!on && runStart >= 0) {
      bands.add([runStart, y - 1]);
      runStart = -1;
    }
  }
  bands.sort((a, b) => (b[1] - b[0]).compareTo(a[1] - a[0]));

  for (final band in bands.take(3)) {
    final bTop = band[0], bBot = band[1];
    final bH = bBot - bTop + 1;
    if (bH < 8 || bH > h) continue;

    // Column profile within the band → bar segmentation.
    final colThr = (bH * 0.10).clamp(2, 1 << 30).toInt();
    final bars = <Bar>[];
    var x0 = -1;
    for (var x = 0; x <= w; x++) {
      var c = 0;
      if (x < w) {
        for (var y = bTop; y <= bBot; y++) {
          if (win.dark(x, y)) c++;
        }
      }
      final on = x < w && c >= colThr;
      if (on && x0 < 0) x0 = x;
      if (!on && x0 >= 0) {
        var yMin = bBot, yMax = bTop;
        for (var bx = x0; bx < x; bx++) {
          for (var y = bTop; y <= bBot; y++) {
            if (win.dark(bx, y)) {
              if (y < yMin) yMin = y;
              if (y > yMax) yMax = y;
            }
          }
        }
        bars.add(Bar(x0, x - 1, yMin - bTop, yMax - bTop));
        x0 = -1;
      }
    }
    if (bars.length < minBars) continue;
    bars.sort((a, b) => a.x0.compareTo(b.x0));
    return bars;
  }
  return null;
}

/// 4-state classification: 0 full, 1 ascender, 2 descender, 3 tracker.
List<int> classify4State(List<Bar> bars) {
  var bandBottom = 0;
  for (final b in bars) {
    if (b.yMax > bandBottom) bandBottom = b.yMax;
  }
  final bandH = bandBottom + 1;
  return bars.map((b) {
    final asc = b.yMin < bandH * 0.2;
    final desc = b.yMax > bandH * 0.8;
    if (asc && desc) return 0;
    if (asc) return 1;
    if (desc) return 2;
    return 3;
  }).toList();
}

/// 2-state (tall = 1 / short = 0) classification for POSTNET / PLANET.
List<int> classify2State(List<Bar> bars) {
  var bandBottom = 0;
  for (final b in bars) {
    if (b.yMax > bandBottom) bandBottom = b.yMax;
  }
  final bandH = bandBottom + 1;
  return bars.map((b) {
    final height = b.yMax - b.yMin + 1;
    return height >= bandH * 0.6 ? 1 : 0;
  }).toList();
}
