import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals/signals_flutter.dart';

import '../state/camera_store.dart';
import 'widgets/common/pill_button.dart';
import 'widgets/controls/bottom_controls.dart';
import 'widgets/controls/filter_selector.dart';
import 'widgets/controls/sensor_tray.dart';
import 'widgets/controls/top_bar.dart';
import 'widgets/overlays/camera_status_widgets.dart';
import 'widgets/overlays/capture_overlays.dart';
import 'widgets/overlays/detection_overlay.dart';
import 'widgets/overlays/filtered_preview.dart';
import 'widgets/overlays/frame_overlay.dart';
import 'widgets/transitions/camera_switch_loader.dart';
import 'widgets/transitions/switch_dim_overlay.dart';

/// The camera screen: preview + gestures (tap-to-focus, pinch-zoom, mode
/// swipe), the control trays, the scanner overlay and the capture overlays.
/// All state lives in [cameraStore]; this widget is pure composition.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  double _baseScale = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cameraStore.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-fetch devices in case they changed (e.g. external camera plugged in)
      cameraStore.init();
    }
  }

  void _handleSwipe(DragEndDetails details) {
    if (details.primaryVelocity == null) return;
    final modes = ['SCANNER', 'PHOTO', 'VIDEO'];
    int currentIndex = modes.indexOf(cameraStore.mode.value);
    if (details.primaryVelocity! < -300) {
      if (currentIndex < modes.length - 1) {
        cameraStore.setMode(modes[currentIndex + 1]);
      }
    } else if (details.primaryVelocity! > 300) {
      if (currentIndex > 0) {
        cameraStore.setMode(modes[currentIndex - 1]);
      }
    }
  }

  void _handleTapToFocus(TapUpDetails details, BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.globalPosition);

    // Correct focus coords if using aspect ratio
    final ar = cameraStore.selectedAspectRatio.value;
    double x = local.dx / box.size.width;
    double y = local.dy / box.size.height;

    if (ar != null) {
      final screenAr = box.size.width / box.size.height;
      if (screenAr > ar) {
        // Width is larger (portrait bars on sides)
        final previewWidth = box.size.height * ar;
        final sideBar = (box.size.width - previewWidth) / 2;
        x = (local.dx - sideBar) / previewWidth;
      } else {
        // Height is larger (portrait bars top/bottom)
        final previewHeight = box.size.width / ar;
        final topBar = (box.size.height - previewHeight) / 2;
        y = (local.dy - topBar) / previewHeight;
      }
    }

    x = x.clamp(0.0, 1.0);
    y = y.clamp(0.0, 1.0);
    cameraStore.setFocusPoint(x, y);
    cameraStore.focusIndicatorTrigger.value = local;
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: never derive the camera resolution from MediaQuery here — doing so
    // reopened the whole camera session on every device rotation (width/height
    // are CameraView lifecycle fields) and raced a stale platform-view binding,
    // which showed as a squeezed/rotated preview. The stream format is fixed
    // (quality selector); the native renderer cover-crops to any surface.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Watch((context) {
        final cameraPermission = cameraStore.cameraPermission.value;
        if (cameraPermission != 1) {
          return PermissionGuard(
            cameraStatus: cameraPermission,
            onGrant: cameraStore.grantPermission,
          );
        }

        final loading = cameraStore.loading.value;
        if (loading) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.cyanAccent),
          );
        }

        return Stack(
          children: [
            // 1. Camera preview + gestures.
            Positioned.fill(
              child: GestureDetector(
                onTapUp: (d) => _handleTapToFocus(d, context),
                onHorizontalDragEnd: _handleSwipe,
                onScaleStart: (_) => _baseScale = cameraStore.currentZoom.value,
                onScaleUpdate: (details) {
                  final newZoom = _baseScale * details.scale;
                  if ((newZoom - cameraStore.currentZoom.value).abs() > 0.05) {
                    HapticFeedback.selectionClick();
                  }
                  cameraStore.setZoom(newZoom);
                },
                behavior: HitTestBehavior.opaque,
                child: Watch((context) {
                  final currentDevice = cameraStore.currentDevice.value;
                  final devices = cameraStore.devices.value;
                  if (devices.isEmpty || currentDevice == null) {
                    return const Center(
                      child: Text(
                        "SELECT A CAMERA",
                        style: TextStyle(color: Colors.white24),
                      ),
                    );
                  }

                  final ar = cameraStore.selectedAspectRatio.value;
                  // Declarative session lifecycle: changing `device` / `width` /
                  // `height` / `fps` reopens the camera (device/format switching
                  // is handled by CameraView, not imperative teardown).
                  final view = CameraView(
                    device: currentDevice,
                    width: cameraStore.width.value,
                    height: cameraStore.height.value,
                    fps: cameraStore.fps.value,
                    // Switches Texture ↔ platform view live (previewMode isn't a
                    // lifecycle field — no camera reopen).
                    previewMode: cameraStore.previewMode.value,
                    resizeMode: cameraStore.resizeCover.value
                        ? PreviewResizeMode.cover
                        : PreviewResizeMode.contain,
                    settleDelay: const Duration(milliseconds: 200),
                    loading: const CameraSwitchLoader(),
                    errorBuilder: (err, retry) =>
                        PreviewError(error: err, onRetry: retry),
                    // Publishes the controller, subscribes to the session event
                    // stream, and re-applies current settings to the new session.
                    onInitialized: cameraStore.onSessionReady,
                    onClosing: cameraStore.onSessionClosing,
                    onError: (err) =>
                        cameraStore.errorMessage.value = err.toString(),
                  );

                  final filtered = FilteredPreview(child: view);
                  return ar == null
                      ? filtered
                      : Center(
                          child: AspectRatio(aspectRatio: ar, child: filtered));
                }),
              ),
            ),

            // 1b. Freeze-dim overlay during session reopen (device / quality /
            // fps switch) — blurs + dims the preview, fades out on ready.
            const Positioned.fill(child: SwitchDimOverlay()),

            // 2a. Zoom indicator.
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).size.height * 0.3,
              child: Watch((context) {
                final zoom = cameraStore.currentZoom.value;
                if (zoom <= 1.02) return const SizedBox.shrink();
                return Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      "${zoom.toStringAsFixed(1)}x",
                      style: const TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                );
              }),
            ),

            // 2b. Tap-to-focus reticle.
            Watch((context) {
              final offset = cameraStore.focusIndicatorTrigger.value;
              if (offset == null) return const SizedBox.shrink();
              return FocusIndicator(key: ValueKey(offset), offset: offset);
            }),

            // 3. Top controls (icon strip + config caption + quick panel; the
            // SETTINGS entry lives inside the quick panel now).
            const TopBar(),

            // 4. Sensor tray (front/back categories + lenses).
            const Positioned(
              bottom: 200,
              left: 0,
              right: 0,
              child: SensorTray(),
            ),

            // 4b. Collapsible filter tray.
            Watch((context) {
              final show = cameraStore.showFilters.value;
              return AnimatedPositioned(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutQuart,
                bottom: show ? 260 : 180,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: show ? 1.0 : 0.0,
                  curve: Curves.easeIn,
                  child: IgnorePointer(
                    ignoring: !show,
                    child: const FilterSelector(),
                  ),
                ),
              );
            }),

            // 5. Scanner overlay (QR / 1D / 2D / ALL).
            Watch((context) {
              final isScanner = cameraStore.mode.value == 'SCANNER';
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: isScanner
                    ? FrameOverlay(
                        key: const ValueKey('scanner'),
                        isProcessing: cameraStore.isProcessingFrames.value,
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              );
            }),

            // 5b. Native ML Kit detection boxes (FACE chip in the top bar).
            Watch((context) {
              final det = cameraStore.nativeDetector.value;
              // Key on the controller so the overlay re-subscribes after a
              // camera switch (new controller instance = new detections
              // stream).
              final ctrl = cameraStore.activeController.value;
              if (det.isEmpty || ctrl == null) return const SizedBox.shrink();
              return DetectionOverlay(key: ValueKey('det_${ctrl.textureId}'));
            }),

            // 6. Bottom main controls.
            const BottomControls(),

            // 7. Global overlays: shutter flash at the native shutter moment.
            Watch((context) {
              final trigger = cameraStore.shutterFlash.value;
              if (trigger == 0) return const SizedBox.shrink();
              return FlashOverlay(key: ValueKey('shutter_$trigger'));
            }),

            // Fast preview thumbnail (photoThumbnail event) — shown instantly,
            // before the full-res JPEG is written.
            Watch((context) {
              final path = cameraStore.lastThumbnailPath.value;
              if (path == null) return const SizedBox.shrink();
              return Positioned(
                left: 16,
                bottom: 200,
                child: ThumbnailBadge(key: ValueKey(path), path: path),
              );
            }),

            // Dev FPS graph (vision-camera enableFpsGraph).
            Watch((context) {
              if (!cameraStore.showFpsGraph.value) {
                return const SizedBox.shrink();
              }
              return Positioned(
                right: 16,
                bottom: 200,
                child:
                    CameraFpsGraph(targetFps: cameraStore.fps.value.toDouble()),
              );
            }),

            Watch((context) {
              if (!cameraStore.isRecording.value) {
                return const SizedBox.shrink();
              }
              return const VideoRecordingHUD();
            }),
          ],
        );
      }),
    );
  }
}
