import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';
import '../../../state/camera_store.dart';

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
                    GestureDetector(
                      onTap: () => _showGallery(context),
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
                            color: isRecording ? Colors.redAccent.withValues(alpha: 0.3) : Colors.white,
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

                    GestureDetector(
                      onTap: isRunning
                          ? () {
                              HapticFeedback.lightImpact();
                              cameraStore.toggleCamera();
                            }
                          : null,
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

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  void _showGallery(BuildContext context) {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black,
      pageBuilder: (ctx, _, _) => _GalleryView(),
    );
  }
}

class _GalleryView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final items = cameraStore.capturedMedia.value.reversed.toList();

      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text(
            "GALLERY",
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
        ),
        body: items.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.photo_library_rounded,
                      color: Colors.white12,
                      size: 60,
                    ),
                    SizedBox(height: 16),
                    Text(
                      "NO MEDIA YET",
                      style: TextStyle(color: Colors.white24, fontSize: 13),
                    ),
                  ],
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return GestureDetector(
                    onTap: () => _openMedia(context, item),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        item.isVideo || item.path.toLowerCase().endsWith(".mp4")
                            ? Container(
                                color: Colors.white10,
                                child: const Icon(
                                  Icons.videocam,
                                  color: Colors.white24,
                                ),
                              )
                            : Image.file(File(item.path), fit: BoxFit.cover),
                        if (item.isVideo)
                          const Center(
                            child: Icon(
                              Icons.play_circle_outline,
                              color: Colors.white70,
                              size: 30,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
      );
    });
  }

  void _openMedia(BuildContext context, ({String path, bool isVideo}) item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _FullscreenView(item: item)),
    );
  }
}

class _FullscreenView extends StatefulWidget {
  final ({String path, bool isVideo}) item;
  const _FullscreenView({required this.item});

  @override
  State<_FullscreenView> createState() => _FullscreenViewState();
}

class _FullscreenViewState extends State<_FullscreenView> {
  VideoPlayerController? _vctrl;

  @override
  void initState() {
    super.initState();
    // Guard against empty / missing files so a failed capture can't crash the
    // player with a FileNotFound on "/".
    if (widget.item.isVideo &&
        widget.item.path.isNotEmpty &&
        File(widget.item.path).existsSync()) {
      _vctrl = VideoPlayerController.file(File(widget.item.path))
        ..initialize().then((_) {
          if (mounted) setState(() {});
        })
        ..setLooping(true)
        ..play();
    }
  }

  @override
  void dispose() {
    _vctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child:
            (widget.item.isVideo ||
                widget.item.path.toLowerCase().endsWith(".mp4"))
            ? (_vctrl != null && _vctrl!.value.isInitialized
                  ? AspectRatio(
                      aspectRatio: _vctrl!.value.aspectRatio,
                      child: VideoPlayer(_vctrl!),
                    )
                  : const CircularProgressIndicator(color: Colors.cyanAccent))
            : Image.file(File(widget.item.path)),
      ),
    );
  }
}
