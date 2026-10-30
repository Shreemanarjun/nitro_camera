import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../state/throughput_controller.dart';
import 'widgets/throughput_panel.dart';

class ThroughputScreen extends StatefulWidget {
  const ThroughputScreen({super.key});

  @override
  State<ThroughputScreen> createState() => _ThroughputScreenState();
}

class _ThroughputScreenState extends State<ThroughputScreen> {
  final _tp = ThroughputController();
  final _server = TextEditingController(
    text: ThroughputController.defaultServer,
  );

  @override
  void initState() {
    super.initState();
    _tp.init();
  }

  @override
  void dispose() {
    _tp.dispose();
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Own Watch: per-scan counter updates must not rebuild the CameraView.
          Watch((context) {
            final device = _tp.device.value;
            if (device == null) return const SizedBox.shrink();
            return CameraView(
              device: device,
              width: 640,
              height: 480,
              fps: 60,
              onInitialized: _tp.onCamera,
              onClosing: () => unawaited(_tp.stopScanner()),
            );
          }),
          ThroughputPanel(tp: _tp, server: _server),
        ],
      ),
    );
  }
}
