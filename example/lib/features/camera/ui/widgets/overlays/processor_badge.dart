import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../../processors/luminance_processor.dart';
import '../../../state/camera_store.dart';

/// Small glass badge showing the active custom [FrameProcessor]'s name and
/// its live output (the demo LUMA processor's mean scene luminance). Purely
/// informational — it never intercepts touches.
class ProcessorBadge extends StatelessWidget {
  const ProcessorBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      top: MediaQuery.of(context).padding.top + 120,
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.40),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Watch((context) {
                final processor = cameraStore.frameProcessor.value;
                if (processor == null) return const SizedBox.shrink();
                // The demo processor exposes a live luminance signal; other
                // implementations just show their name.
                final value = processor is LuminanceFrameProcessor
                    ? ' ${(processor.luminance.value * 100).round()}%'
                    : '';
                // Live profiling (vision-camera-style): processed FPS + mean
                // processFrame cost, once the first 1 s window has closed.
                final fps = cameraStore.processorFps.value;
                final ms = cameraStore.processorAvgMs.value;
                final stats = fps > 0
                    ? ' \u00b7 ${fps.toStringAsFixed(0)}FPS'
                          ' ${ms.toStringAsFixed(1)}ms'
                    : '';
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.memory_rounded,
                      size: 12,
                      color: Colors.cyanAccent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${processor.name}$value$stats',
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
