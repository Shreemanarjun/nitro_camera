import 'dart:math' as math;

/// Nearest-rank percentiles — the same formula as the RN bench's computeStats.
class Stats {
  final int samples;
  final double avgMs, medianMs, p95Ms, minMs, maxMs;
  const Stats._(
    this.samples,
    this.avgMs,
    this.medianMs,
    this.p95Ms,
    this.minMs,
    this.maxMs,
  );

  factory Stats.of(Iterable<double> timings) {
    final s = timings.toList()..sort();
    if (s.isEmpty) return const Stats._(0, 0, 0, 0, 0, 0);
    double at(double p) => s[math.min(s.length - 1, (p * s.length).floor())];
    return Stats._(
      s.length,
      s.reduce((a, b) => a + b) / s.length,
      at(0.5),
      at(0.95),
      s.first,
      s.last,
    );
  }

  Map<String, Object> toJson() => {
    'samples': samples,
    'avgMs': avgMs,
    'medianMs': medianMs,
    'p95Ms': p95Ms,
    'minMs': minMs,
    'maxMs': maxMs,
  };
}

class BenchResult {
  final String title, detail;
  final Stats stats;
  final List<String> values;
  final double detectRate;
  final int inputs;
  const BenchResult(
    this.title,
    this.detail,
    this.stats,
    this.values,
    this.detectRate,
    this.inputs,
  );

  BenchResult.error(Object e)
    : this('Error', '$e', Stats.of(const []), const [], 0, 0);

  Map<String, Object> toJson() => {
    'title': title,
    'detail': detail,
    'engine': 'nitro_camera-zxing',
    'stats': stats.toJson(),
    'values': values,
    'detectRate': detectRate,
    'inputs': inputs,
  };
}

/// Per-scan timings + decoded values, as the RN SampleCollector counts them.
class Collector {
  final timings = <double>[];
  final values = <String, int>{};
  int scans = 0, hits = 0;

  void scan(double ms) {
    timings.add(ms);
    scans++;
  }

  void hit(String value) {
    hits++;
    values[value] = (values[value] ?? 0) + 1;
  }

  BenchResult result(String title, String detail) {
    final sorted = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return BenchResult(
      title,
      detail,
      Stats.of(timings),
      [for (final e in sorted) e.key],
      scans == 0 ? 0 : hits / scans,
      scans,
    );
  }
}
