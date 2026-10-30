import 'package:flutter/material.dart';

import '../../logic/bench_stats.dart';
import '../bench_theme.dart';

class BenchResultCard extends StatelessWidget {
  const BenchResultCard({super.key, required this.result});

  final BenchResult result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final s = r.stats;
    final decoded = r.values.isEmpty
        ? '⚠︎ nothing decoded'
        : '✓ "${r.values.join(' | ')}"';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${r.title} — ${r.detail}',
            style: benchMono.copyWith(color: Colors.white70),
          ),
          Text(
            '${s.medianMs.toStringAsFixed(1)} ms median',
            style: benchMono.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            'avg ${s.avgMs.toStringAsFixed(1)} · p95 ${s.p95Ms.toStringAsFixed(1)} · min ${s.minMs.toStringAsFixed(1)} · max ${s.maxMs.toStringAsFixed(1)}',
            style: benchMono,
          ),
          Text(
            '${r.inputs} scans · ${(r.detectRate * 100).toStringAsFixed(0)}% decoded',
            style: benchMono,
          ),
          Text(
            decoded,
            style: benchMono.copyWith(
              color: r.values.isEmpty
                  ? Colors.orangeAccent
                  : Colors.greenAccent,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
