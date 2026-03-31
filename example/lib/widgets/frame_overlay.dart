import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _frameCount = ValueNotifier<int>(0);
  final List<DateTime> _frames = [];
  StreamSubscription? _sub;
  String? _lastResult;
  Timer? _resultClearTimer;

  @override
  void initState() {
    super.initState();
    _sub = NitroCamera.instance.frameStream.listen((frame) {
      if (!mounted || !widget.isProcessing) return;
      
      // SAMPLE THE STREAM: only analyze every 10th frame to avoid CPU saturation
      if (_frameCount.value % 10 != 0) {
        _frameCount.value++;
        return;
      }

      _updateStats();
      _analyzeAndProcess(frame);
    });
  }

  void _updateStats() {
    final now = DateTime.now();
    _frames.add(now);
    _frames.removeWhere((f) => now.difference(f).inSeconds > 1);
    _fpsCounter.value = _frames.length.toDouble();
    _frameCount.value++;
  }

  bool _isAnalyzing = false;

  Future<void> _analyzeAndProcess(CameraFrame frame) async {
    if (_isAnalyzing) return;
    _isAnalyzing = true;

    try {
      final result = await compute(_analyzeInBackground, {
        'frame': frame,
      });

      if (result != null && mounted) {
        if (_lastResult == null) {
          HapticFeedback.vibrate();
          HapticFeedback.selectionClick();
        }
        setState(() {
          _lastResult = result;
          _resultClearTimer?.cancel();
          _resultClearTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => _lastResult = null);
          });
        });
      } else if (mounted && _lastResult != null) {
        // If NOTHING found in frame, clear the result immediately to allow "rescanning" 
        // as soon as the camera moves away from the previous QR.
        setState(() => _lastResult = null);
      }

      if (mounted && kDebugMode) {
        await _updateDisplay(frame);
      }
    } finally {
      _isAnalyzing = false;
    }
  }

  static Future<String?> _analyzeInBackground(dynamic input) async {
    try {
      final frame = input['frame'] as CameraFrame;
      final ls = _NitroLuminanceSource(frame.pixels, frame.width, frame.height);
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
    _frameCount.dispose();
    _resultClearTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isProcessing) return const SizedBox.shrink();

    return IgnorePointer(
      child: Stack(
        children: [
          // 0. Dimmed Background with Scanner Cutout
          const Positioned.fill(child: _TacticalScannerOverlay()),

          // 1. Stats Dashboard (Top Left)
          Positioned(
            left: 20,
            top: 100,
            child: _AnimatedStatsCard(
              fpsCounter: _fpsCounter,
              frameCount: _frameCount,
              lastResult: _lastResult,
            ),
          ),

          // 2. Corner Debug View (Small Preview)
          if (_image != null)
            Positioned(
              right: 20,
              top: 80,
              child: Container(
                width: 90,
                height: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.cyanAccent.withValues(alpha: 0.1),
                      blurRadius: 10,
                    )
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: RawImage(image: _image, fit: BoxFit.cover),
                ),
              ),
            ),

          // 3. QR Viewfinder (Premium Design)
          Center(
            child: _PremiumViewfinder(
              isScanning: widget.isProcessing,
              hasResult: _lastResult != null,
            ),
          ),

          // 4. Detected Result (Floating Glass Card)
          if (_lastResult != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 280),
                child: _QRResultCard(result: _lastResult!),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnimatedStatsCard extends StatelessWidget {
  final ValueNotifier<double> fpsCounter;
  final ValueNotifier<int> frameCount;
  final String? lastResult;

  const _AnimatedStatsCard({
    required this.fpsCounter,
    required this.frameCount,
    this.lastResult,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatItem(
                icon: Icons.bolt,
                label: "STREAM",
                value: ValueListenableBuilder<double>(
                  valueListenable: fpsCounter,
                  builder: (ctx, v, _) => Text("${v.toInt()} FPS", style: _valStyle),
                ),
                color: Colors.cyanAccent,
              ),
              const SizedBox(height: 12),
              _StatItem(
                icon: Icons.numbers,
                label: "FRAMES",
                value: ValueListenableBuilder<int>(
                  valueListenable: frameCount,
                  builder: (ctx, v, _) => Text(v.toString(), style: _valStyle),
                ),
                color: Colors.white70,
              ),
              const SizedBox(height: 12),
              _StatItem(
                icon: Icons.qr_code_scanner,
                label: "SCANNER",
                value: Text(lastResult != null ? "FOUND" : "SCANNING", style: _valStyle.copyWith(
                  color: lastResult != null ? Colors.greenAccent : Colors.white38,
                )),
                color: lastResult != null ? Colors.greenAccent : Colors.white24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _valStyle = TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900, fontFamily: 'monospace');
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget value;
  final Color color;
  const _StatItem({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            value,
          ],
        ),
      ],
    );
  }
}

class _PremiumViewfinder extends StatelessWidget {
  final bool isScanning;
  final bool hasResult;

  const _PremiumViewfinder({required this.isScanning, required this.hasResult});

  @override
  Widget build(BuildContext context) {
    final color = hasResult ? Colors.greenAccent : Colors.cyanAccent;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.9, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.elasticOut,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 280,
            height: 280,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(48),
              border: Border.all(color: color.withValues(alpha: 0.1), width: 2),
              boxShadow: isScanning ? [
                 BoxShadow(
                   color: color.withValues(alpha: 0.05),
                   blurRadius: 40,
                   spreadRadius: 10,
                 )
              ] : null,
            ),
            child: Stack(
              children: [
                ...List.generate(4, (i) => Positioned(
                  top: i < 2 ? -2 : null,
                  bottom: i >= 2 ? -2 : null,
                  left: i % 2 == 0 ? -2 : null,
                  right: i % 2 != 0 ? -2 : null,
                  child: _Corner(index: i, color: color),
                )),
                if (isScanning && !hasResult) const _ScanningBeam(),
                if (hasResult)
                  Center(
                    child: _PulseCircle(color: Colors.greenAccent),
                  ),
                if (hasResult) ...[
                  const _SuccessFlash(),
                  const Center(child: Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 60)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Corner extends StatelessWidget {
  final int index;
  final Color color;
  const _Corner({required this.index, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 45,
      height: 45,
      decoration: BoxDecoration(
        border: Border(
          top: index < 2 ? BorderSide(color: color, width: 5) : BorderSide.none,
          bottom: index >= 2 ? BorderSide(color: color, width: 5) : BorderSide.none,
          left: index % 2 == 0 ? BorderSide(color: color, width: 5) : BorderSide.none,
          right: index % 2 != 0 ? BorderSide(color: color, width: 5) : BorderSide.none,
        ),
        borderRadius: BorderRadius.only(
          topLeft: index == 0 ? const Radius.circular(22) : Radius.zero,
          topRight: index == 1 ? const Radius.circular(22) : Radius.zero,
          bottomLeft: index == 2 ? const Radius.circular(22) : Radius.zero,
          bottomRight: index == 3 ? const Radius.circular(22) : Radius.zero,
        ),
      ),
    );
  }
}

class _PulseCircle extends StatelessWidget {
  final Color color;
  const _PulseCircle({required this.color});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.5, end: 1.2),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Container(
        width: 200 * value,
        height: 200 * value,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: (1.0 - value).clamp(0, 1)),
            width: 3,
          ),
        ),
      ),
    );
  }
}

class _ScanningBeam extends StatefulWidget {
  const _ScanningBeam();
  @override
  State<_ScanningBeam> createState() => _ScanningBeamState();
}

class _ScanningBeamState extends State<_ScanningBeam> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500))..repeat(reverse: true);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Positioned(
        top: 260 * Curves.easeInOut.transform(_ctrl.value),
        left: 30,
        right: 30,
        child: Container(
          height: 3,
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.6), blurRadius: 20, spreadRadius: 2)
            ],
            gradient: LinearGradient(colors: [
              Colors.cyanAccent.withValues(alpha: 0),
              Colors.cyanAccent,
              Colors.cyanAccent.withValues(alpha: 0),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SuccessFlash extends StatelessWidget {
  const _SuccessFlash();
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, value, _) => Container(
        decoration: BoxDecoration(
          color: Colors.greenAccent.withValues(alpha: (1.0 - value) * 0.2),
          borderRadius: BorderRadius.circular(48),
        ),
      ),
    );
  }
}

class _TacticalScannerOverlay extends StatelessWidget {
  const _TacticalScannerOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _ScannerHolePainter(),
    );
  }
}

class _ScannerHolePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(0, 0, size.width, size.height);
    final hole = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 280,
      height: 280,
    );
    final rhole = RRect.fromRectAndRadius(hole, const Radius.circular(48));

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect),
        Path()..addRRect(rhole),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _QRResultCard extends StatelessWidget {
  final String result;
  const _QRResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutQuart,
      builder: (context, value, child) => Transform.translate(
        offset: Offset(0, 40 * (1 - value)),
        child: Opacity(opacity: value.clamp(0, 1), child: child),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.3), width: 2),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.greenAccent, size: 28),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "SCAN SUCCESS",
                          style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          result,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                       // Placeholder for action like open URL or copy
                    },
                    icon: const Icon(Icons.copy_rounded, color: Colors.white38, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NitroLuminanceSource extends zxing.LuminanceSource {
  final Uint8List pixels;
  _NitroLuminanceSource(this.pixels, int width, int height) : super(width, height);
  @override
  Uint8List get matrix => pixels;
  @override
  Uint8List getRow(int y, Uint8List? row) {
    if (y < 0 || y >= height) throw Exception("Bounds error");
    final start = y * width;
    final res = row ?? Uint8List(width);
    res.setRange(0, width, pixels, start);
    return res;
  }
  @override
  bool get isCropSupported => false;
}
