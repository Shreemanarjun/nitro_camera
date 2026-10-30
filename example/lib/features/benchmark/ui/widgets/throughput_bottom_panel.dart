import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../state/throughput_controller.dart';
import '../bench_theme.dart';
import 'bench_button.dart';
import 'throughput_counter.dart';

/// Negotiated camera config, counter, error and Start/Stop + Back.
class ThroughputBottomPanel extends StatelessWidget {
  const ThroughputBottomPanel({
    super.key,
    required this.tp,
    required this.server,
  });

  final ThroughputController tp;
  final TextEditingController server;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: benchPanel,
      // Keep the buttons above the system navigation bar.
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Watch((context) {
            final state = tp.state.value;
            final config = tp.config.value;
            final error = tp.error.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (config.isNotEmpty) ...[
                  Text(
                    config,
                    style: const TextStyle(color: benchInfo, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                ],
                ThroughputCounter(tp: tp),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    error,
                    style: const TextStyle(color: benchError, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: BenchButton(
                        primary: true,
                        label: state.active
                            ? 'Stop'
                            : 'Start ${ThroughputController.target} QRs (${tp.engine.value.name})',
                        onPressed: state == ThroughputState.preparing
                            ? null
                            : (state.active
                                  ? tp.stop
                                  : () => tp.start(server.text)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: BenchButton(
                        label: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ],
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}
