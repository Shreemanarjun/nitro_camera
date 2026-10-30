import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../state/decode_bench_controller.dart';
import 'widgets/decode_readout_bar.dart';
import 'widgets/decode_run_panel.dart';

class DecodeBenchScreen extends StatefulWidget {
  const DecodeBenchScreen({super.key});

  @override
  State<DecodeBenchScreen> createState() => _DecodeBenchScreenState();
}

class _DecodeBenchScreenState extends State<DecodeBenchScreen> {
  final _bench = DecodeBenchController();

  @override
  void initState() {
    super.initState();
    unawaited(_bench.init());
  }

  @override
  void dispose() {
    _bench.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Watch((context) {
        final device = _bench.device.value;
        if (device == null) {
          return Center(
            child: Text(
              _bench.status.value,
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }
        return CameraView(
          device: device,
          // 1280×720 — the format the RN example's vision-camera picks by
          // default, so the live-camera numbers are like-for-like.
          width: 1280,
          height: 720,
          fps: 30,
          onInitialized: _bench.onCamera,
          onClosing: () => unawaited(_bench.stopScanner()),
          // The bar and panel watch their own signals, so readout ticks never
          // rebuild the CameraView.
          child: SafeArea(
            child: Column(
              children: [
                DecodeReadoutBar(bench: _bench),
                const Spacer(),
                DecodeRunPanel(bench: _bench),
              ],
            ),
          ),
        );
      }),
    );
  }
}
