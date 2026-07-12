import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A tiny dev overlay that graphs the app's actual render frame-rate — the
/// Flutter analogue of vision-camera's `enableFpsGraph`.
///
/// It samples the interval between rendered frames via a [Ticker] and draws a
/// rolling bar graph plus the current FPS. Intended for debugging only.
class CameraFpsGraph extends StatefulWidget {
  const CameraFpsGraph({
    super.key,
    this.width = 108,
    this.height = 44,
    this.samples = 48,
    this.targetFps = 60,
  });

  /// Graph size.
  final double width;
  final double height;

  /// How many recent frames to keep in the rolling window.
  final int samples;

  /// The reference (max) fps used to scale the bars.
  final double targetFps;

  @override
  State<CameraFpsGraph> createState() => _CameraFpsGraphState();
}

class _CameraFpsGraphState extends State<CameraFpsGraph> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final ValueNotifier<List<double>> _history = ValueNotifier<List<double>>([]);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    if (_last != Duration.zero) {
      final dt = (elapsed - _last).inMicroseconds / 1e6;
      if (dt > 0) {
        final list = List<double>.of(_history.value)..add(1.0 / dt);
        if (list.length > widget.samples) {
          list.removeRange(0, list.length - widget.samples);
        }
        _history.value = list;
      }
    }
    _last = elapsed;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ValueListenableBuilder<List<double>>(
        valueListenable: _history,
        builder: (_, history, _) => CustomPaint(
          painter: _FpsPainter(history, widget.targetFps),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _FpsPainter extends CustomPainter {
  _FpsPainter(this.history, this.targetFps);
  final List<double> history;
  final double targetFps;

  @override
  void paint(Canvas canvas, Size size) {
    final current = history.isEmpty ? 0.0 : history.last;
    // Colour by how close we are to target.
    final ratio = (current / targetFps).clamp(0.0, 1.0);
    final color = Color.lerp(Colors.redAccent, Colors.greenAccent, ratio)!;

    // Bars.
    if (history.isNotEmpty) {
      final bw = size.width / history.length;
      final paint = Paint()..color = color.withValues(alpha: 0.75);
      for (var i = 0; i < history.length; i++) {
        final h = (history[i] / targetFps).clamp(0.0, 1.0) * size.height;
        canvas.drawRect(
          Rect.fromLTWH(i * bw, size.height - h, bw * 0.8, h),
          paint,
        );
      }
    }

    // Current FPS label.
    final tp = TextPainter(
      text: TextSpan(
        text: '${current.round()} FPS',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(0, 0));
  }

  @override
  bool shouldRepaint(covariant _FpsPainter old) => old.history != history;
}
