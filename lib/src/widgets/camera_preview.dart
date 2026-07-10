import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controller/camera_controller.dart';

/// How the preview fills its box (vision-camera's `resizeMode`).
enum PreviewResizeMode {
  /// Fill the box, cropping overflow (default).
  cover,

  /// Fit entirely inside the box, letterboxing as needed.
  contain,
}

/// Defines how the camera preview is rendered.
enum PreviewMode {
  /// Renders using Flutter's [Texture] widget. Best for performance and layering.
  texture,

  /// Renders using a native [AndroidView]. Uses hardware overlays for better
  /// battery efficiency but harder to layer Flutter widgets on top.
  ///
  /// **Android only** — no iOS platform view is registered, so on other
  /// platforms this falls back to [texture].
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
    this.mode = PreviewMode.platformView,
    this.resizeMode = PreviewResizeMode.cover,
    this.child,
  });

  /// The initialised [CameraController] providing the texture.
  final CameraController controller;

  /// The rendering mode to use.
  final PreviewMode mode;

  /// How the preview fills its box — [PreviewResizeMode.cover] (crop) or
  /// [PreviewResizeMode.contain] (letterbox).
  final PreviewResizeMode resizeMode;

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

        // Platform views only exist on Android — elsewhere fall back to the
        // Texture path instead of building an AndroidView that renders nothing.
        final effectiveMode = (mode == PreviewMode.platformView &&
                defaultTargetPlatform != TargetPlatform.android)
            ? PreviewMode.texture
            : mode;

        Widget preview;
        switch (effectiveMode) {
          case PreviewMode.platformView:
            // Plain AndroidView + a TextureView-backed native view: Flutter
            // composites it via the Texture Layer path — correct aspect and
            // z-order. (A SurfaceView-backed view either falls back to Virtual
            // Display → slightly squeezed, or punches through behind Flutter
            // under Hybrid Composition → black preview.)
            // Key on textureId: creationParams are only sent at creation, so a
            // session reopen (new textureId) must create a NEW platform view —
            // otherwise the view stays bound to the dead session.
            preview = AndroidView(
              key: ValueKey('nitra_pv_${controller.textureId}'),
              viewType: 'dev.shreeman.nitro_camera/platform_view',
              creationParams: {'textureId': controller.textureId},
              creationParamsCodec: const StandardMessageCodec(),
            );
          case PreviewMode.impeller:
          case PreviewMode.texture:
            final texture = Texture(textureId: controller.textureId!);
            if (defaultTargetPlatform == TargetPlatform.android) {
              // The native GL renderer draws the FULL upright frame into the
              // producer surface (whose size Flutter controls and may not match
              // any aspect). Declaring the true content aspect here makes the
              // buffer's arbitrary aspect cancel out — same contract as iOS.
              // Content is upright, so swap stream dims when the sensor-vs-display
              // rotation leaves it portrait.
              final isLandscapeDisplay =
                  MediaQuery.of(context).orientation == Orientation.landscape;
              final sensorRotated = controller.sensorOrientation % 180 != 0;
              final contentPortrait = sensorRotated != isLandscapeDisplay;
              final logicalWidth =
                  contentPortrait ? controller.height : controller.width;
              final logicalHeight =
                  contentPortrait ? controller.width : controller.height;
              preview = FittedBox(
                fit: resizeMode == PreviewResizeMode.contain
                    ? BoxFit.contain
                    : BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: logicalWidth.toDouble(),
                  height: logicalHeight.toDouble(),
                  child: texture,
                ),
              );
            } else {
              // iOS delivers the raw camera buffer via the Texture, so frame it
              // here: size a box to the (orientation-corrected) stream aspect and
              // cover/contain-fit it.
              final isPortrait = controller.sensorOrientation % 180 != 0;
              final logicalWidth =
                  isPortrait ? controller.height : controller.width;
              final logicalHeight =
                  isPortrait ? controller.width : controller.height;
              preview = FittedBox(
                fit: resizeMode == PreviewResizeMode.contain
                    ? BoxFit.contain
                    : BoxFit.cover,
                child: SizedBox(
                  width: logicalWidth.toDouble(),
                  height: logicalHeight.toDouble(),
                  child: texture,
                ),
              );
            }
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
    this.minZoom,
    this.maxZoom,
  });

  final CameraController controller;
  final Widget child;

  /// Zoom clamp overrides. Default to the device's own
  /// [CameraDeviceInfo.minZoom] / [CameraDeviceInfo.maxZoom] range.
  final double? minZoom;
  final double? maxZoom;

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
        final device = widget.controller.device;
        final newZoom = (_baseZoom * details.scale).clamp(
          widget.minZoom ?? device.minZoom,
          widget.maxZoom ?? device.maxZoom,
        );
        widget.controller.setZoom(newZoom);
      },
      child: widget.child,
    );
  }
}
