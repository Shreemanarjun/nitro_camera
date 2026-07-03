import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:nitro_camera/nitro_camera.dart';
import '../../../state/camera_store.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final width = cameraStore.width.value;
      final fps = cameraStore.fps.value;

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      // QUALITY TOGGLE
                      _TacticalUnit(
                        label: width == 1280 ? "720P" : "1080P",
                        onTap: () => cameraStore.setResolution(
                          width == 1280 ? 1920 : 1280,
                          width == 1280 ? 1080 : 720,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // FPS TOGGLE
                      _TacticalUnit(
                        label: "$fps FPS",
                        onTap: () => cameraStore.setFps(fps == 30 ? 60 : 30),
                      ),
                      const SizedBox(width: 12),
                      // ASPECT RATIO TOGGLE
                      Watch((context) {
                        final ar = cameraStore.selectedAspectRatio.value;
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
                              cameraStore.selectedAspectRatio.value = 16 / 9;
                            } else if ((ar - 16 / 9).abs() < 0.01) {
                              cameraStore.selectedAspectRatio.value = 4 / 3;
                            } else if ((ar - 4 / 3).abs() < 0.01) {
                              cameraStore.selectedAspectRatio.value = 1.0;
                            } else {
                              cameraStore.selectedAspectRatio.value = null;
                            }
                          },
                        );
                      }),
                      const SizedBox(width: 12),
                      // FILTER TOGGLE
                      Watch((context) {
                        final show = cameraStore.showFilters.value;
                        return _TacticalUnit(
                          label: "FILTERS",
                          onTap: () => cameraStore.showFilters.value = !show,
                          active: show,
                        );
                      }),
                      const SizedBox(width: 12),
                      // PREVIEW MODE TOGGLE
                      Watch((context) {
                        final mode = cameraStore.previewMode.value;
                        String label;
                        switch (mode) {
                          case PreviewMode.texture:
                            label = "TEXTURE";
                          case PreviewMode.platformView:
                            label = "PV";
                          case PreviewMode.impeller:
                            label = "IMPELLER";
                        }
                        return _TacticalUnit(
                          label: label,
                          active: mode == PreviewMode.platformView,
                          onTap: () {
                            // Clean 2-way switch: Texture ↔ platform view.
                            final next = mode == PreviewMode.platformView
                                ? PreviewMode.texture
                                : PreviewMode.platformView;
                            cameraStore.setPreviewMode(next);
                          },
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // FLASH TOGGLE
              Watch((context) {
                final current = cameraStore.currentDevice.value;
                if (current == null || current.hasFlash) {
                  return const SizedBox.shrink();
                }

                final flash = cameraStore.flashMode.value;
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
                    cameraStore.setFlash(next);
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
