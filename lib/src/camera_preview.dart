import 'package:flutter/material.dart';
import 'camera_controller.dart';

/// Renders the live camera preview using Flutter's GPU-accelerated [Texture] widget.
///
/// Wrap in an [AspectRatio] or [SizedBox] to control the layout size.
/// Place [child] widgets on top of the preview (e.g. controls overlay).
///
/// Example:
/// ```dart
/// CameraPreview(
///   controller: _controller,
///   child: Align(
///     alignment: Alignment.bottomCenter,
///     child: CaptureButton(onPressed: _takePhoto),
///   ),
/// )
/// ```
class CameraPreview extends StatelessWidget {
  const CameraPreview({
    super.key,
    required this.controller,
    this.child,
  });

  /// The initialised [CameraController] providing the texture.
  final CameraController controller;

  /// Optional overlay widget rendered on top of the camera preview.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isInitialized) {
          return const Center(child: CircularProgressIndicator());
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Texture(textureId: controller.textureId!),
            ?child,
          ],
        );
      },
    );
  }
}

/// A [GestureDetector] wrapper that translates tap positions to normalised
/// camera coordinates (0.0–1.0) and calls [controller.setFocusPoint].
class TapToFocusDetector extends StatelessWidget {
  const TapToFocusDetector({
    super.key,
    required this.controller,
    required this.child,
  });

  final CameraController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(details.globalPosition);
        final x = (local.dx / box.size.width).clamp(0.0, 1.0);
        final y = (local.dy / box.size.height).clamp(0.0, 1.0);
        controller.setFocusPoint(x, y);
      },
      child: child,
    );
  }
}

/// A pinch-to-zoom wrapper that drives [controller.setZoom].
class PinchToZoomDetector extends StatefulWidget {
  const PinchToZoomDetector({
    super.key,
    required this.controller,
    required this.child,
    this.minZoom = 1.0,
    this.maxZoom = 8.0,
  });

  final CameraController controller;
  final Widget child;
  final double minZoom;
  final double maxZoom;

  @override
  State<PinchToZoomDetector> createState() => _PinchToZoomDetectorState();
}

class _PinchToZoomDetectorState extends State<PinchToZoomDetector> {
  double _baseZoom = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (_) => _baseZoom = widget.controller.zoom,
      onScaleUpdate: (details) {
        final newZoom = (_baseZoom * details.scale)
            .clamp(widget.minZoom, widget.maxZoom);
        widget.controller.setZoom(newZoom);
      },
      child: widget.child,
    );
  }
}
