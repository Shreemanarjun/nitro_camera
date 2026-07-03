import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';

/// Full-preview freeze overlay for session reopens (device / resolution / fps
/// switch): blurs and dims whatever is on screen the instant the switch starts,
/// then crossfades away once [CameraStatus.running] returns — the stock-camera
/// "frozen frame" feel instead of a spinner. Sits above the preview but below
/// every control, and never intercepts touches.
class SwitchDimOverlay extends StatelessWidget {
  const SwitchDimOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final switching = cameraStore.isSwitching.value;
      return IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: switching ? 1.0 : 0.0),
          // Snap in fast so the teardown frame is covered immediately; ease
          // out slowly so the fresh preview crossfades in underneath.
          duration: Duration(milliseconds: switching ? 140 : 420),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) {
            if (t <= 0.001) return const SizedBox.shrink();
            return ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18 * t, sigmaY: 18 * t),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.45 * t),
                ),
              ),
            );
          },
        ),
      );
    });
  }
}
