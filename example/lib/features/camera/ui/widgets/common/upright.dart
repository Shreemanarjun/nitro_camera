import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../../state/camera_store.dart';

/// Keeps [child] upright as the phone rotates, the way a camera app turns its
/// buttons while the screen itself stays portrait. Animates the shortest way
/// round, so going from -90° to 180° turns 90° back rather than 270° forward.
class Upright extends StatefulWidget {
  final Widget child;

  /// Rotation source in degrees; defaults to [CameraStore.uiRotation].
  final ReadonlySignal<int>? rotation;

  const Upright({super.key, required this.child, this.rotation});

  @override
  State<Upright> createState() => _UprightState();
}

class _UprightState extends State<Upright> {
  int? _degrees;
  double _turns = 0;

  /// Accumulates the shortest signed step from the last angle, so the
  /// animation never takes the long way round.
  double _turnsFor(int degrees) {
    final last = _degrees;
    if (last == null) {
      _turns = degrees / 360;
    } else if (degrees != last) {
      final step = (degrees - last + 540) % 360 - 180; // -180..179
      _turns += step / 360;
    }
    _degrees = degrees;
    return _turns;
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.rotation ?? cameraStore.uiRotation;
    return Watch(
      (_) => AnimatedRotation(
        turns: _turnsFor(source.value),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
