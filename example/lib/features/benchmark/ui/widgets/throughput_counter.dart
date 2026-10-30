import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../state/throughput_controller.dart';
import '../bench_theme.dart';

/// The big accepted-scan count, the run clock and a one-line status.
class ThroughputCounter extends StatelessWidget {
  const ThroughputCounter({super.key, required this.tp});

  final ThroughputController tp;

  @override
  Widget build(BuildContext context) {
    const target = ThroughputController.target;
    return Watch((context) {
      final state = tp.state.value;
      final count = tp.count.value;
      final status = switch (state) {
        ThroughputState.preparing => 'Resetting server and warming HTTP…',
        ThroughputState.running when count == 0 =>
          'Waiting for the first accepted QR…',
        ThroughputState.completed =>
          '$target confirmations / ${target - 1} timed intervals',
        _ => '',
      };
      return Column(
        children: [
          Text(
            '$count',
            style: const TextStyle(
              color: benchCount,
              fontSize: 96,
              fontWeight: FontWeight.w800,
              shadows: [Shadow(blurRadius: 8)],
            ),
          ),
          Text(
            '${(tp.elapsedMs.value / 1000).toStringAsFixed(3)}s',
            style: benchText,
          ),
          Text(status, style: benchText),
        ],
      );
    });
  }
}
