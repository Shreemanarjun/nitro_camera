import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'dart:io';
import '../../../../gallery/ui/gallery_screen.dart';
import '../../../state/camera_store.dart';
import '../common/glass_tooltip.dart';

class BottomControls extends StatelessWidget {
  const BottomControls({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final mode = cameraStore.mode.value;
      final lastCapturedPath = cameraStore.lastCapturedPath.value;
      final isLastCapturedVideo = cameraStore.isLastCapturedVideo.value;
      final isRunning = cameraStore.status.value == CameraStatus.running;
      final isRecording = cameraStore.isRecording.value;

      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          padding: const EdgeInsets.only(bottom: 60),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                isRecording ? Colors.red.withValues(alpha: 0.1) : Colors.transparent,
                Colors.black.withValues(alpha: 0.6)
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),

              // MODE SWIPER
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: ['SCANNER', 'PHOTO', 'VIDEO'].map((m) {
                    final isSelected = mode == m;
                    return GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        cameraStore.setMode(m);
                      },
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              m,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.amberAccent
                                    : Colors.white54,
                                fontWeight: isSelected
                                    ? FontWeight.w900
                                    : FontWeight.normal,
                                fontSize: 13,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              width: isSelected ? 4 : 0,
                              height: 4,
                              decoration: const BoxDecoration(
                                color: Colors.amberAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              // RECORDING TIMER
              if (isRecording)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Watch((context) {
                    final duration = cameraStore.recordingDuration.value;
                    return Text(
                      _formatDuration(duration),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    );
                  }),
                ),
              const SizedBox(height: 12),

              // MAIN CONTROLS
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GlassTooltip(
                      message: 'Gallery',
                      preferBelow: false,
                      child: GestureDetector(
                        onTap: () => openGallery(context),
                        child: Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24, width: 2),
                            image:
                                lastCapturedPath != null &&
                                    !isLastCapturedVideo &&
                                    !lastCapturedPath.toLowerCase().endsWith(
                                      ".mp4",
                                    )
                                ? DecorationImage(
                                    image: FileImage(File(lastCapturedPath)),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child:
                              lastCapturedPath != null && isLastCapturedVideo
                              ? const Icon(
                                  Icons.play_circle_fill,
                                  color: Colors.white,
                                  size: 28,
                                )
                              : (lastCapturedPath == null
                                    ? const Icon(
                                        Icons.photo_library_outlined,
                                        color: Colors.white12,
                                        size: 24,
                                      )
                                    : null),
                        ),
                      ),
                    ),

                    GlassTooltip(
                      message: mode == 'VIDEO'
                          ? (isRecording ? 'Stop recording' : 'Record video')
                          : 'Take photo',
                      preferBelow: false,
                      child: GestureDetector(
                        onTap: isRunning
                            ? () {
                                HapticFeedback.mediumImpact();
                                if (mode == 'PHOTO' || mode == 'SCANNER') {
                                  cameraStore.takePhoto();
                                } else if (mode == 'VIDEO') {
                                  cameraStore.toggleRecording();
                                }
                              }
                            : null,
                        child: Container(
                          width: 82,
                          height: 82,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isRecording
                                  ? Colors.redAccent.withValues(alpha: 0.3)
                                  : Colors.white,
                              width: 4,
                            ),
                          ),
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: isRecording ? 30 : 64,
                              height: isRecording ? 30 : 64,
                              decoration: BoxDecoration(
                                color: (mode == 'VIDEO' || isRecording)
                                    ? Colors.redAccent
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(
                                  isRecording ? 8 : 40,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    _FlipCameraButton(enabled: isRunning),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return "$m:$s";
  }
}

/// Camera-flip control: each tap spins the glyph a half turn in sync with the
/// freeze-dim switch transition (stock-camera flip feedback instead of a
/// loader).
class _FlipCameraButton extends StatefulWidget {
  final bool enabled;
  const _FlipCameraButton({required this.enabled});

  @override
  State<_FlipCameraButton> createState() => _FlipCameraButtonState();
}

class _FlipCameraButtonState extends State<_FlipCameraButton> {
  double _turns = 0;

  @override
  Widget build(BuildContext context) {
    return GlassTooltip(
      message: 'Switch camera',
      preferBelow: false,
      child: GestureDetector(
        onTap: widget.enabled
            ? () {
                HapticFeedback.lightImpact();
                setState(() => _turns += 0.5);
                cameraStore.toggleCamera();
              }
            : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.enabled ? 1.0 : 0.55,
          child: Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: AnimatedRotation(
              turns: _turns,
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeInOutCubic,
              child: const Icon(
                Icons.sync_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
