import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../state/decode_bench_controller.dart';
import '../bench_theme.dart';

/// Live per-frame readout (refreshed every 500 ms) + the QR / ALL toggle.
class DecodeReadoutBar extends StatelessWidget {
  const DecodeReadoutBar({super.key, required this.bench});

  final DecodeBenchController bench;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Watch((context) {
        final c = bench.camera.value;
        final ro = bench.readout.value;
        final running = bench.running.value;
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'nitro_camera · ZXing · ${c == null ? '…' : '${c.width}x${c.height}'} · full frame',
                    style: benchMono,
                  ),
                  Text(
                    '${ro.ms.toStringAsFixed(1)} ms · ${ro.fps.toStringAsFixed(0)} fps · ${(ro.hitRatio * 100).toStringAsFixed(0)}% decoded',
                    style: benchMono,
                  ),
                  Text(
                    ro.text ?? 'No barcodes yet',
                    style: benchMono.copyWith(color: Colors.greenAccent),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SegmentedButton<CodeScanKind>(
              segments: const [
                ButtonSegment(value: CodeScanKind.qr, label: Text('QR')),
                ButtonSegment(value: CodeScanKind.all, label: Text('ALL')),
              ],
              selected: {bench.kind.value},
              onSelectionChanged: running
                  ? null
                  : (s) => bench.selectKind(s.first),
            ),
          ],
        );
      }),
    );
  }
}
