import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../state/throughput_controller.dart';
import '../bench_theme.dart';
import 'engine_toggle.dart';

/// Server origin + engine picker, both locked while a run is active.
class ThroughputTopBar extends StatelessWidget {
  const ThroughputTopBar({super.key, required this.tp, required this.server});

  final ThroughputController tp;
  final TextEditingController server;

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final active = tp.state.value.active;
      final engine = tp.engine.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: server,
            enabled: !active,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: benchScrim,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final (i, e) in ThroughputEngine.values.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: EngineToggle(
                    label: e.label,
                    selected: e == engine,
                    onTap: active ? null : () => tp.selectEngine(e),
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    });
  }
}
