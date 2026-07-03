import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shown while the camera session is being reopened (device / quality / fps
/// switch, ~500–800 ms of hardware open/close). A stock-camera-style flip
/// animation reads as an intentional transition instead of a stall.
class CameraSwitchLoader extends StatefulWidget {
  const CameraSwitchLoader({super.key, this.label = 'SWITCHING CAMERA'});

  final String label;

  @override
  State<CameraSwitchLoader> createState() => _CameraSwitchLoaderState();
}

class _CameraSwitchLoaderState extends State<CameraSwitchLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                final t = Curves.easeInOutCubic.transform(_ctrl.value);
                // Y-axis coin flip with a slight breathing scale.
                final angle = t * math.pi * 2;
                final scale = 0.92 + 0.08 * math.sin(t * math.pi);
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // Expanding pulse ring.
                    Container(
                      width: 96 + 44 * t,
                      height: 96 + 44 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.cyanAccent
                              .withValues(alpha: 0.35 * (1 - t)),
                          width: 1.5,
                        ),
                      ),
                    ),
                    Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0016)
                        ..rotateY(angle)
                        ..scaleByDouble(scale, scale, scale, 1),
                      child: Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.06),
                          border: Border.all(
                            color: Colors.cyanAccent.withValues(alpha: 0.5),
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.cameraswitch_rounded,
                          color: Colors.cyanAccent,
                          size: 38,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 28),
            Text(
              widget.label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
