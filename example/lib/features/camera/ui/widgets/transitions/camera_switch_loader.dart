import 'package:flutter/material.dart';

/// Shown by [CameraView] in place of the preview while the session reopens.
/// Deliberately quiet: a near-black surface with a faint breathing glow — the
/// switch feedback itself comes from the freeze-dim overlay above the preview
/// and the rotating flip control, not from a spinner.
class CameraSwitchLoader extends StatefulWidget {
  const CameraSwitchLoader({super.key});

  @override
  State<CameraSwitchLoader> createState() => _CameraSwitchLoaderState();
}

class _CameraSwitchLoaderState extends State<CameraSwitchLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.1,
              colors: [
                Color.lerp(
                  const Color(0xFF0C1214),
                  const Color(0xFF131C20),
                  t,
                )!,
                Colors.black,
              ],
            ),
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}
