import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:nitro_camera/nitro_camera.dart';
import '../camera_state.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final width = CameraState.width.value;
      final fps = CameraState.fps.value;

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              // QUALITY TOGGLE
              _TacticalUnit(
                label: width == 1280 ? "720P" : "1080P",
                onTap: () => CameraState.setResolution(
                  width == 1280 ? 1920 : 1280,
                  width == 1280 ? 1080 : 720,
                ),
              ),
              const SizedBox(width: 12),
              // FPS TOGGLE
              _TacticalUnit(
                label: "$fps FPS",
                onTap: () => CameraState.setFps(fps == 30 ? 60 : 30),
              ),
              const SizedBox(width: 12),
              // ASPECT RATIO TOGGLE
              Watch((context) {
                final ar = CameraState.selectedAspectRatio.value;
                String label;
                if (ar == null) {
                  label = "FULL";
                } else if ((ar - 1.0).abs() < 0.01) {
                  label = "1:1";
                } else if ((ar - 4 / 3).abs() < 0.01) {
                  label = "4:3";
                } else {
                  label = "16:9";
                }

                return _TacticalUnit(
                  label: label,
                  onTap: () {
                    if (ar == null) {
                      CameraState.selectedAspectRatio.value = 16 / 9;
                    } else if ((ar - 16 / 9).abs() < 0.01) {
                      CameraState.selectedAspectRatio.value = 4 / 3;
                    } else if ((ar - 4 / 3).abs() < 0.01) {
                      CameraState.selectedAspectRatio.value = 1.0;
                    } else {
                      CameraState.selectedAspectRatio.value = null;
                    }
                  },
                );
              }),
              const SizedBox(width: 12),
              // FILTER TOGGLE
              Watch((context) {
                final show = CameraState.showFilters.value;
                return _TacticalUnit(
                  label: "FILTERS",
                  onTap: () => CameraState.showFilters.value = !show,
                  active: show,
                );
              }),
              const Spacer(),
              // FLASH TOGGLE
              Watch((context) {
                final current = CameraState.currentDevice.value;
                if (current == null || current.hasFlash == 0) {
                  return const SizedBox.shrink();
                }

                final flash = CameraState.flashMode.value;
                IconData icon;
                Color color;
                switch (flash) {
                  case FlashMode.off:
                    icon = Icons.flash_off_rounded;
                    color = Colors.white30;
                    break;
                  case FlashMode.on:
                    icon = Icons.flash_on_rounded;
                    color = Colors.amberAccent;
                    break;
                  case FlashMode.auto:
                    icon = Icons.flash_auto_rounded;
                    color = Colors.cyanAccent;
                    break;
                }
                return GestureDetector(
                  onTap: () {
                    final modes = FlashMode.values;
                    final next = modes[(flash.index + 1) % modes.length];
                    CameraState.setFlash(next);
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      icon,
                      key: ValueKey(flash),
                      color: color,
                      size: 28,
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      );
    });
  }
}

class _TacticalUnit extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _TacticalUnit({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? Colors.cyanAccent
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? Colors.white : Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
