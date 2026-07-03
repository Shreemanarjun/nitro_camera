import 'binarizer.dart';

/// Extracts bar/space run widths (in pixels) along horizontal scanlines of a
/// [GrayWindow], for width-modulated linear symbologies (MSI, Code 11,
/// Industrial 2-of-5, Telepen, Pharmacode one-track).
///
/// Returns one run list per attempted scanline. Each list starts and ends
/// with a **bar** run (leading/trailing quiet space trimmed): even indices
/// are bars, odd are spaces. Lists with fewer than [minRuns] runs are
/// dropped.
List<List<int>> extractScanlineRuns(
  GrayWindow win, {
  int minRuns = 7,
  List<double> rowFractions = const [0.5, 0.38, 0.62, 0.26, 0.74],
}) {
  final out = <List<int>>[];
  for (final f in rowFractions) {
    final y = (win.height * f).round().clamp(0, win.height - 1);
    final runs = _runsAtRow(win, y);
    if (runs != null && runs.length >= minRuns) out.add(runs);
  }
  return out;
}

List<int>? _runsAtRow(GrayWindow win, int y) {
  final w = win.width;
  final runs = <int>[];
  var current = win.dark(0, y);
  var runLen = 1;
  var sawBar = false;
  for (var x = 1; x <= w; x++) {
    final d = x < w && win.dark(x, y);
    if (x < w && d == current) {
      runLen++;
      continue;
    }
    // close the run
    if (current) sawBar = true;
    if (sawBar) runs.add(runLen);
    if (!sawBar && current == false) {
      // still leading quiet zone — skip
    }
    current = d;
    runLen = 1;
  }
  if (runs.isEmpty) return null;
  // First recorded run is a bar by construction; trim a trailing space run.
  if (runs.length.isEven) runs.removeLast();
  return runs;
}

/// Normalizes pixel run widths to integer units (1..[maxUnit]) using the
/// narrowest element as the module estimate. Returns null when any run
/// exceeds [maxUnit] units (not this symbology / noise).
List<int>? runsToUnits(List<int> runs, {int maxUnit = 4}) {
  if (runs.isEmpty) return null;
  var narrow = runs.reduce((a, b) => a < b ? a : b);
  if (narrow <= 0) return null;
  // Refine: average of runs within 1.5× of the minimum.
  var sum = 0.0, n = 0;
  for (final r in runs) {
    if (r <= narrow * 1.5) {
      sum += r;
      n++;
    }
  }
  final module = n > 0 ? sum / n : narrow.toDouble();
  final units = <int>[];
  for (final r in runs) {
    final u = (r / module).round().clamp(1, 1 << 30);
    if (u > maxUnit) return null;
    units.add(u);
  }
  return units;
}
