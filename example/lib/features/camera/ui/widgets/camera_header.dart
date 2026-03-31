import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import '../../state/camera_state.dart';
import 'dart:ui' as ui;

class CameraHeader extends StatelessWidget {
  final CameraStatus status;
  final CameraDevice? currentDevice;
  final int width;
  final int height;
  final int fps;

  const CameraHeader({
    super.key,
    required this.status,
    required this.currentDevice,
    required this.width,
    required this.height,
    required this.fps,
  });

  @override
  Widget build(BuildContext context) {
    final isRunning = status == CameraStatus.running;
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Row(
              children: [
                _StatusIndicator(status: status),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        currentDevice?.name.toUpperCase() ?? "SELECT SOURCE",
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                      if (isRunning) ...[
                        const SizedBox(height: 2),
                        Text(
                          "RECORDING READY • ${width}x$height @ $fps FPS",
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 8, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isRunning)
                  const Icon(Icons.videocam_outlined, color: Colors.cyanAccent, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final CameraStatus status;
  const _StatusIndicator({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    bool isPulse = false;

    switch (status) {
      case CameraStatus.running:
        color = Colors.greenAccent;
        label = "LIVE";
        isPulse = true;
        break;
      case CameraStatus.opening:
        color = Colors.amberAccent;
        label = "PENDING";
        break;
      case CameraStatus.error:
        color = Colors.redAccent;
        label = "ERROR";
        break;
      default:
        color = Colors.white24;
        label = "OFF";
    }

    return Row(
      children: [
        if (isPulse) _PulseDot(color: color) else Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
      ],
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, child) => Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.3 + (0.7 * _ctrl.value)),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: widget.color.withValues(alpha: 0.5 * _ctrl.value), blurRadius: 4 * _ctrl.value, spreadRadius: 2 * _ctrl.value)
          ],
        ),
      ),
    );
  }
}
