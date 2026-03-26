import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:zxing_lib/zxing.dart' as zxing;
import 'package:zxing_lib/common.dart' as zxing;
import 'package:zxing_lib/qrcode.dart' as zxing;

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
  String? _lastResult;
  Timer? _resultClearTimer;
  bool _forceNextFrame = false;
  bool _isManualScanning = false;

  @override
  void initState() {
    super.initState();
    debugPrint("FrameOverlay initialized. isProcessing: ${widget.isProcessing}");
    _sub = NitroCamera.instance.frameStream.listen((frame) {
      debugPrint("Frame received in Dart! textureId=${frame.textureId}");
      if (!mounted || !widget.isProcessing) return;
      _updateFps();
      _analyzeAndProcess(frame);
    });
  }

  void _updateFps() {
    final now = DateTime.now();
    _frames.add(now);
    _frames.removeWhere((f) => now.difference(f).inSeconds > 1);
    _fpsCounter.value = _frames.length.toDouble();
  }

  bool _isAnalyzing = false;

  Future<void> _analyzeAndProcess(CameraFrame frame) async {
    if (_isAnalyzing) return;
    _isAnalyzing = true;

    final shouldForce = _forceNextFrame;
    if (shouldForce) _forceNextFrame = false;

    try {
      if (shouldForce) {
        debugPrint("MANUAL ANALYSIS TRIGGERED: Waiting for next frame...");
        setState(() => _isManualScanning = true);
      }
      final result = await compute(_analyzeInBackground, {
        'frame': frame,
        'force': shouldForce,
      });
      if (shouldForce && mounted) {
        debugPrint("MANUAL ANALYSIS FINISHED. Result: $result");
        setState(() => _isManualScanning = false);
      }
      if (result != null && mounted) {
        setState(() {
          _lastResult = result;
          _resultClearTimer?.cancel();
          _resultClearTimer = Timer(const Duration(seconds: 3), () {
            if (mounted) setState(() => _lastResult = null);
          });
        });
      }

      // 2. Process for Display (still on UI thread for ui.Image)
      if (mounted) {
        await _updateDisplay(frame);
      }
    } finally {
      _isAnalyzing = false;
    }
  }

  static Future<String?> _analyzeInBackground(dynamic input) async {
    try {
      final frame = input['frame'] as CameraFrame;
      final force = input['force'] as bool;
      if (force) debugPrint("Applying high-precision scanner hints...");

      // 1. Create LuminanceSource
      final ls = _NitroLuminanceSource(frame.pixels, frame.width, frame.height);

      // 2. Decode
      final bitmap = zxing.BinaryBitmap(zxing.HybridBinarizer(ls));
      final reader = zxing.QRCodeReader();
      
      final result = reader.decode(bitmap);
      
      return result.text;
    } catch (_) {
      return null;
    }
  }

  Future<void> _updateDisplay(CameraFrame frame) async {
    final bytes = frame.pixels;
    final width = frame.width;
    final height = frame.height;

    // Note: ui.decodeImageFromPixels expects RGBA.
    // If you use YUV (PixelFormat.yuv), you'd need a different shader or conversion here.
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
                  border: Border.all(
                    color: Colors.cyanAccent.withValues(alpha: 0.5),
                    width: 2,
                  ),
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
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
          // 3. Manual Analyze Button
          Positioned(
            left: 20,
            top: 100,
            child: FloatingActionButton.extended(
              onPressed: _isManualScanning ? null : () => setState(() => _forceNextFrame = true),
              backgroundColor: _isManualScanning ? Colors.grey : Colors.cyanAccent.withValues(alpha: 0.9),
              icon: _isManualScanning 
                ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.flash_on, color: Colors.black),
              label: Text(
                _isManualScanning ? "SCANNING..." : "ANALYZE", 
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 10)
              ),
            ),
          ),
          // 4. Centered QR Viewfinder
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _lastResult != null ? Colors.greenAccent : Colors.white24,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Stack(
                children: [
                  // Corner Brackets
                  Positioned(top: 0, left: 0, child: _ViewfinderCorner(quadrant: 0, color: _lastResult != null ? Colors.greenAccent : Colors.cyanAccent)),
                  Positioned(top: 0, right: 0, child: _ViewfinderCorner(quadrant: 1, color: _lastResult != null ? Colors.greenAccent : Colors.cyanAccent)),
                  Positioned(bottom: 0, left: 0, child: _ViewfinderCorner(quadrant: 2, color: _lastResult != null ? Colors.greenAccent : Colors.cyanAccent)),
                  Positioned(bottom: 0, right: 0, child: _ViewfinderCorner(quadrant: 3, color: _lastResult != null ? Colors.greenAccent : Colors.cyanAccent)),
                  
                  // Scanning Line (if processing)
                  if (widget.isProcessing)
                    const _ScanningLine(),
                ],
              ),
            ),
          ),
          if (_lastResult != null)
            Positioned(
              left: 40,
              right: 40,
              top: 180, // High enough to clear the control panel
              child: AnimatedOpacity(
                opacity: 1.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.cyanAccent.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 15,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.qr_code_2, size: 40, color: Colors.black),
                      const SizedBox(height: 10),
                      const Text(
                        "DETECTED DATA",
                        style: TextStyle(
                          color: Colors.black54,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _lastResult!,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Helper class to bridge Nitro pixels to ZXing LuminanceSource
class _NitroLuminanceSource extends zxing.LuminanceSource {
  final Uint8List pixels;
  _NitroLuminanceSource(this.pixels, int width, int height)
    : super(width, height);

  @override
  Uint8List get matrix => pixels;

  @override
  Uint8List getRow(int y, Uint8List? row) {
    if (y < 0 || y >= height) throw Exception("Index out of bounds");
    final start = y * width;
    final res = row ?? Uint8List(width);
    res.setRange(0, width, pixels, start);
    return res;
  }

  @override
  bool get isCropSupported => false;
}

class _ViewfinderCorner extends StatelessWidget {
  final int quadrant;
  final Color color;
  const _ViewfinderCorner({required this.quadrant, required this.color});

  @override
  Widget build(BuildContext context) {
    const double size = 30;
    const double thickness = 4;
    
    return Container(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CornerPainter(quadrant: quadrant, color: color, thickness: thickness),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final int quadrant;
  final Color color;
  final double thickness;
  _CornerPainter({required this.quadrant, required this.color, required this.thickness});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke;

    final path = Path();
    if (quadrant == 0) { // Top Left
      path.moveTo(0, size.height);
      path.lineTo(0, 0);
      path.lineTo(size.width, 0);
    } else if (quadrant == 1) { // Top Right
      path.moveTo(size.width - size.width, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height);
    } else if (quadrant == 2) { // Bottom Left
      path.moveTo(0, size.height - size.height);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
    } else { // Bottom Right
      path.moveTo(size.width, size.height - size.height);
      path.lineTo(size.width, size.height);
      path.lineTo(size.width - size.width, size.height);
    }
    
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _ScanningLine extends StatefulWidget {
  const _ScanningLine();
  @override
  State<_ScanningLine> createState() => _ScanningLineState();
}

class _ScanningLineState extends State<_ScanningLine> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Positioned(
          top: 250 * _controller.value,
          left: 10,
          right: 10,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.cyanAccent.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
              gradient: LinearGradient(
                colors: [
                  Colors.cyanAccent.withValues(alpha: 0),
                  Colors.cyanAccent,
                  Colors.cyanAccent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
