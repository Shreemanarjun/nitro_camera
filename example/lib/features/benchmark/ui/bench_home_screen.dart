import 'package:flutter/material.dart';

import 'decode_bench_screen.dart';
import 'throughput_screen.dart';

/// Picks the two benchmarks. Each screen owns its camera, so popping back here
/// closes the session before the other one opens.
class BenchHomeScreen extends StatelessWidget {
  const BenchHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DecodeBenchScreen(),
                ),
              ),
              child: const Text('Decode benchmark (live + bundled image)'),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ThroughputScreen(),
                ),
              ),
              child: const Text('1000-QR throughput (qr-server)'),
            ),
          ],
        ),
      ),
    );
  }
}
