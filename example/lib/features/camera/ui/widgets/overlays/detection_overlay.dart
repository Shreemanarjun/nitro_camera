import 'dart:async';

import 'package:flutter/material.dart';

import '../../../state/camera_store.dart';

/// Live bounding boxes from the NATIVE ML Kit detector
/// (`controller.setNativeDetector('face' | 'barcode')`). Payload boxes are in
/// un-rotated sensor-buffer coordinates; this maps them through the sensor
/// rotation (+ front mirror) onto the cover-fitted preview.
class DetectionOverlay extends StatefulWidget {
  const DetectionOverlay({super.key});

  @override
  State<DetectionOverlay> createState() => _DetectionOverlayState();
}

class _DetectionOverlayState extends State<DetectionOverlay> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic>? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _error;
  Timer? _errorClear;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    final ctrl = cameraStore.activeController.value;
    if (ctrl == null) return;
    _sub = ctrl.nativeDetections.listen((payload) {
      if (!mounted) return;
      setState(() {
        if (payload['error'] != null) {
          _error = payload['error'] as String;
          _last = null;
          // Auto-dismiss the banner: transient detector errors (e.g. during a
          // camera switch) shouldn't stick around forever.
          _errorClear?.cancel();
          _errorClear = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _error = null);
          });
        } else {
          // A good payload supersedes any earlier error banner.
          _errorClear?.cancel();
          _errorClear = null;
          _error = null;
          _last = payload;
          _lastAt = DateTime.now();
        }
      });
    });
  }

  @override
  void dispose() {
    _errorClear?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 210),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final payload = _last;
    if (payload == null ||
        DateTime.now().difference(_lastAt).inMilliseconds > 800) {
      return const SizedBox.shrink();
    }
    final isFront =
        cameraStore.currentDevice.value?.isFrontCamera ?? false;
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _DetectionPainter(payload, isFront),
      ),
    );
  }
}

class _DetectionPainter extends CustomPainter {
  final Map<String, dynamic> payload;
  final bool mirrored;
  _DetectionPainter(this.payload, this.mirrored);

  @override
  void paint(Canvas canvas, Size size) {
    final w = (payload['width'] as num?)?.toDouble() ?? 0;
    final h = (payload['height'] as num?)?.toDouble() ?? 0;
    final rotation = (payload['rotation'] as num?)?.toInt() ?? 0;
    final results = payload['results'] as List? ?? const [];
    if (w <= 0 || h <= 0 || results.isEmpty) return;

    // Upright content dims after the sensor rotation.
    final uprightW = rotation % 180 == 0 ? w : h;
    final uprightH = rotation % 180 == 0 ? h : w;
    // Cover-fit the upright frame onto the screen.
    final sx = size.width / uprightW, sy = size.height / uprightH;
    final scale = sx > sy ? sx : sy;
    final dx = (size.width - uprightW * scale) / 2;
    final dy = (size.height - uprightH * scale) / 2;

    Offset mapPoint(double px, double py) {
      var nx = px / w, ny = py / h;
      switch (rotation) {
        case 90:
          final t = nx;
          nx = 1.0 - ny;
          ny = t;
        case 180:
          nx = 1.0 - nx;
          ny = 1.0 - ny;
        case 270:
          final t = nx;
          nx = ny;
          ny = 1.0 - t;
      }
      if (mirrored) nx = 1.0 - nx;
      return Offset(dx + nx * uprightW * scale, dy + ny * uprightH * scale);
    }

    final stroke = Paint()
      ..color = Colors.orangeAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final labelStyle = const TextStyle(
      color: Colors.orangeAccent,
      fontSize: 10,
      fontWeight: FontWeight.w900,
    );

    for (final r in results) {
      final b = (r as Map)['bounds'] as List?;
      if (b == null || b.length < 4) continue;
      final p1 = mapPoint((b[0] as num).toDouble(), (b[1] as num).toDouble());
      final p2 = mapPoint((b[2] as num).toDouble(), (b[3] as num).toDouble());
      final rect = Rect.fromPoints(p1, p2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(10)),
        stroke,
      );
      final label = r['text'] as String? ??
          (r['smilingProbability'] != null
              ? 'smile ${((r['smilingProbability'] as num) * 100).toStringAsFixed(0)}%'
              : payload['detector'] as String? ?? '');
      if (label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: rect.width + 80);
        tp.paint(canvas, Offset(rect.left, rect.top - tp.height - 4));
      }
    }
  }

  @override
  bool shouldRepaint(_DetectionPainter old) =>
      old.payload != payload || old.mirrored != mirrored;
}
