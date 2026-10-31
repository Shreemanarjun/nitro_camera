import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../state/throughput_controller.dart';
import 'widgets/throughput_bottom_panel.dart';
import 'widgets/throughput_top_bar.dart';

/// Same layout as the RN example's ThroughputScreen: full-bleed camera,
/// server + engine picker at the top, the counter panel at the bottom.
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
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Own Watch: per-scan counter updates must not rebuild the CameraView.
          Watch((context) {
            final device = _tp.device.value;
            if (device == null) return const SizedBox.shrink();
            return CameraView(
              device: device,
              // Same streams as the RN app: CameraX's 1640×1232 preview
              // (measured via dumpsys) over 640×480 analysis frames.
              width: 1640,
              height: 1232,
              frameWidth: 640,
              frameHeight: 480,
              photo: false, // no still stream, like the RN session
              fps: 60,
              onInitialized: _tp.onCamera,
              onClosing: () => unawaited(_tp.stopScanner()),
            );
          }),
          Positioned(
            top: 60,
            left: 16,
            right: 16,
            child: ThroughputTopBar(tp: _tp, server: _server),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ThroughputBottomPanel(tp: _tp, server: _server),
          ),
        ],
      ),
    );
  }
}
