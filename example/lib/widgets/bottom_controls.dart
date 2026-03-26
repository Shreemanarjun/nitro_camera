import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'dart:io';
import '../camera_state.dart';

class BottomControls extends StatelessWidget {
  const BottomControls({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final mode = CameraState.mode.value;
      final lastCapturedPath = CameraState.lastCapturedPath.value;
      final isLastCapturedVideo = CameraState.isLastCapturedVideo.value;
      final isRunning = CameraState.status.value == CameraStatus.running;
      final isRecording = CameraState.isRecording.value;

      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          padding: const EdgeInsets.only(bottom: 60),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
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
                        CameraState.setMode(m);
                      },
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Text(
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
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),

              // MAIN CONTROLS
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      onTap: lastCapturedPath != null
                          ? () => _showMediaFullscreen(
                                context,
                                lastCapturedPath,
                                isLastCapturedVideo,
                              )
                          : null,
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 2),
                          image:
                              lastCapturedPath != null && !isLastCapturedVideo
                              ? DecorationImage(
                                  image: FileImage(File(lastCapturedPath)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: lastCapturedPath != null && isLastCapturedVideo
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

                    GestureDetector(
                      onTap: isRunning
                          ? () {
                              HapticFeedback.mediumImpact();
                              if (mode == 'PHOTO' || mode == 'SCANNER') {
                                CameraState.takePhoto();
                              } else if (mode == 'VIDEO') {
                                CameraState.toggleRecording();
                              }
                            }
                          : null,
                      child: Container(
                        width: 82,
                        height: 82,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
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

                    GestureDetector(
                      onTap: isRunning ? () {
                        HapticFeedback.lightImpact();
                        CameraState.toggleCamera();
                      } : null,
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.sync_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  void _showMediaFullscreen(BuildContext context, String path, bool isVideo) {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black,
      pageBuilder: (ctx, _, _) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: isVideo
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.video_library_rounded,
                          color: Colors.white10,
                          size: 80,
                        ),
                        SizedBox(height: 24),
                        Text(
                          "VIDEO PREVIEW",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          "Playback requires additional integration",
                          style: TextStyle(color: Colors.white24, fontSize: 11),
                        ),
                      ],
                    )
                  : Hero(tag: 'media_preview', child: Image.file(File(path))),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
