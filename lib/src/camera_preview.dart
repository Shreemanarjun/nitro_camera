import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'camera_controller.dart';

/// Defines how the camera preview is rendered.
enum PreviewMode {
  /// Renders using Flutter's [Texture] widget. Best for performance and layering.
  texture,

  /// Renders using a native [AndroidView] or [UiKitView]. Uses hardware overlays
  /// for better battery efficiency but harder to layer Flutter widgets on top.
  platformView,

  /// Renders using [Texture] but wrapped in an Impeller-optimized fragment shader.
  impeller,
}

/// Renders the live camera preview using Flutter's GPU-accelerated [Texture] widget
/// or a native Platform View.
///
/// Wrap in an [AspectRatio] or [SizedBox] to control the layout size.
class CameraPreview extends StatelessWidget {
  const CameraPreview({
    super.key,
    required this.controller,
    this.mode = PreviewMode.texture,
    this.child,
  });

  /// The initialised [CameraController] providing the texture.
  final CameraController controller;

  /// The rendering mode to use.
  final PreviewMode mode;

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

        Widget preview;
        switch (mode) {
          case PreviewMode.platformView:
            preview = AndroidView(
              viewType: 'dev.shreeman.nitro_camera/platform_view',
              creationParams: {'textureId': controller.textureId},
              creationParamsCodec: const StandardMessageCodec(),
            );
          case PreviewMode.impeller:
          case PreviewMode.texture:
            final isPortrait = controller.sensorOrientation % 180 != 0;
            final logicalWidth = isPortrait ? controller.height : controller.width;
            final logicalHeight = isPortrait ? controller.width : controller.height;

            preview = FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: logicalWidth.toDouble(),
                height: logicalHeight.toDouble(),
                child: Texture(textureId: controller.textureId!),
              ),
            );
        }

        return Stack(
          fit: StackFit.expand,
          children: [preview, ?child],
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
        controller.focus(x, y);
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
        final newZoom = (_baseZoom * details.scale).clamp(
          widget.minZoom,
          widget.maxZoom,
        );
        widget.controller.setZoom(newZoom);
      },
      child: widget.child,
    );
  }
}
