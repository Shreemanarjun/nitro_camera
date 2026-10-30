import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../state/decode_bench_controller.dart';
import 'bench_result_card.dart';

/// Run button, current phase and the result cards.
class DecodeRunPanel extends StatelessWidget {
  const DecodeRunPanel({super.key, required this.bench});

  final DecodeBenchController bench;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Watch((context) {
        final running = bench.running.value;
        final results = bench.results.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: running ? null : bench.run,
              child: Text(running ? bench.phase.value : 'Run benchmark'),
            ),
            if (results.isEmpty && !running)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Aim at a barcode, then run: 6 s of live frames, then the bundled QR image ×30.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            for (final r in results) BenchResultCard(result: r),
          ],
        );
      }),
    );
  }
}
