import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../state/throughput_controller.dart';
import '../bench_theme.dart';

/// Server origin, the run clock + count, negotiated config, status and the
/// Start / Stop button.
class ThroughputPanel extends StatelessWidget {
  const ThroughputPanel({super.key, required this.tp, required this.server});

  final ThroughputController tp;
  final TextEditingController server;

  @override
  Widget build(BuildContext context) {
    const target = ThroughputController.target;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Watch((context) {
          final state = tp.state.value;
          final count = tp.count.value;
          final config = tp.config.value;
          final status = switch (state) {
            ThroughputState.idle =>
              'Start the qr-server on the LAN, show its page fullscreen, aim, then Start.',
            ThroughputState.preparing => 'Resetting server and warming HTTP…',
            ThroughputState.running =>
              count == 0
                  ? 'Waiting for the first accepted QR…'
                  : 'Running — $target confirmations / ${target - 1} timed intervals',
            ThroughputState.completed =>
              'Completed: $target confirmations, ${target - 1} timed intervals\n${tp.diagnostics}',
            ThroughputState.stopped => 'Stopped',
            ThroughputState.failed => 'Failed: ${tp.error.value}',
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: server,
                enabled: !state.active,
                style: benchMono,
                decoration: const InputDecoration(
                  labelText: 'qr-server origin',
                  labelStyle: TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.black54,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${(tp.elapsedMs.value / 1000).toStringAsFixed(3)} s',
                style: benchMono.copyWith(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '$count / $target accepted · nitro_camera · ZXing',
                style: benchMono,
              ),
              if (config.isNotEmpty)
                Text(config, style: benchMono.copyWith(color: Colors.white70)),
              if (state == ThroughputState.running)
                Text(
                  'analyzing ${tp.fps.value.toStringAsFixed(0)} fps',
                  style: benchMono.copyWith(color: Colors.white70),
                ),
              const SizedBox(height: 4),
              Text(
                status,
                style: benchMono.copyWith(
                  color: state == ThroughputState.failed
                      ? Colors.orangeAccent
                      : Colors.greenAccent,
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: state == ThroughputState.preparing
                    ? null
                    : (state.active ? tp.stop : () => tp.start(server.text)),
                child: Text(state.active ? 'Stop' : 'Start $target QRs'),
              ),
            ],
          );
        }),
      ),
    );
  }
}
