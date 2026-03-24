import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'dart:ui' as ui;

class FrameOverlay extends StatefulWidget {
  final bool isProcessing;
  const FrameOverlay({super.key, required this.isProcessing});

  @override
  State<FrameOverlay> createState() => _FrameOverlayState();
}

class _FrameOverlayState extends State<FrameOverlay> {
  ui.Image? _image;
  final _fpsCounter = ValueNotifier<double>(0);
  final List<DateTime> _frames = [];
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = NitroCamera.instance.frameStream.listen((frame) {
      if (!mounted || !widget.isProcessing) return;
      _updateFps();
      _processFrame(frame);
    });
  }

  void _updateFps() {
    final now = DateTime.now();
    _frames.add(now);
    _frames.removeWhere((f) => now.difference(f).inSeconds > 1);
    _fpsCounter.value = _frames.length.toDouble();
  }

  Future<void> _processFrame(CameraFrame frame) async {
    final bytes = frame.pixels;
    final width = frame.width;
    final height = frame.height;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    
    final img = await completer.future;
    if (mounted) {
      setState(() {
        _image?.dispose();
        _image = img;
      });
    } else {
      img.dispose();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _image?.dispose();
    _fpsCounter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isProcessing) return const SizedBox.shrink();

    return IgnorePointer(
      child: Stack(
        children: [
          if (_image != null)
            Positioned(
              right: 20,
              top: 100,
              width: 120,
              height: 160,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.5), width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: RawImage(image: _image, fit: BoxFit.cover),
                ),
              ),
            ),
          Positioned(
            right: 20,
            top: 270,
            child: ValueListenableBuilder<double>(
              valueListenable: _fpsCounter,
              builder: (ctx, fps, _) => Text(
                "PROCESSOR: ${fps.toInt()} FPS",
                style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
