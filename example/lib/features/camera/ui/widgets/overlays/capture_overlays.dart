import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';
import '../../theme/app_theme.dart';

/// White full-screen flash fired at the *native* shutter moment
/// (photoCaptureShutter event).
class FlashOverlay extends StatefulWidget {
  const FlashOverlay({super.key});
  @override
  State<FlashOverlay> createState() => _FlashOverlayState();
}

class _FlashOverlayState extends State<FlashOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _ctrl.forward().then((_) {
      if (mounted) _ctrl.reverse();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: _ctrl,
        child: Container(color: Colors.white),
      ),
    );
  }
}

/// REC pill with a pulsing dot + elapsed time. The single recording timer —
/// reads the store's [recordingDuration] (synced with the native start) rather
/// than an independent widget-local clock, so it never drifts.
class VideoRecordingHUD extends StatelessWidget {
  const VideoRecordingHUD({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 120,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PulseDot(),
              const SizedBox(width: 10),
              Watch((context) {
                final s = cameraStore.recordingDuration.value;
                final str =
                    '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
                return Text(
                  str,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    fontSize: 16,
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: AppColors.danger,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Tap-to-focus reticle that fades out and clears its store trigger.
class FocusIndicator extends StatefulWidget {
  final Offset offset;
  const FocusIndicator({super.key, required this.offset});

  @override
  State<FocusIndicator> createState() => _FocusIndicatorState();
}

class _FocusIndicatorState extends State<FocusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _ctrl.forward().then((_) {
      if (cameraStore.focusIndicatorTrigger.value == widget.offset) {
        cameraStore.focusIndicatorTrigger.value = null;
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.offset.dx - 35,
      top: widget.offset.dy - 35,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: ReverseAnimation(_ctrl),
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 1.5),
              color: Colors.white.withValues(alpha: 0.1),
            ),
            child: const Center(
              child: Icon(
                Icons.center_focus_weak,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The fast preview thumbnail delivered by the `photoThumbnail` event;
/// auto-dismisses after a couple seconds. Tapping it jumps straight into the
/// media viewer on the freshly captured item.
class ThumbnailBadge extends StatefulWidget {
  final String path;
  final VoidCallback? onTap;
  const ThumbnailBadge({super.key, required this.path, this.onTap});
  @override
  State<ThumbnailBadge> createState() => _ThumbnailBadgeState();
}

class _ThumbnailBadgeState extends State<ThumbnailBadge> {
  bool _visible = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!File(widget.path).existsSync()) return const SizedBox.shrink();
    return IgnorePointer(
      // Once faded out it must not swallow taps meant for the preview.
      ignoring: !_visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: _visible ? 1 : 0,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.accent, width: 1.5),
              image: DecorationImage(
                image: FileImage(File(widget.path)),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
