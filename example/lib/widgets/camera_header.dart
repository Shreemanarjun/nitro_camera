import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import '../widgets/control_panel.dart'; // For CameraStatus

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
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildInfoChip(
            isRunning ? "ACTIVE" : status.name.toUpperCase(),
            isRunning ? Colors.greenAccent : Colors.amberAccent,
          ),
          if (isRunning) ...[
            _buildInfoChip("${width}x$height", Colors.white70),
            _buildInfoChip("$fps FPS", Colors.white70),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1),
      ),
    );
  }
}
