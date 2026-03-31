import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'dart:async';
import 'package:nitro/nitro.dart';
import 'features/camera/state/camera_state.dart';
import 'features/camera/ui/widgets/camera_preview.dart';
import 'features/camera/ui/widgets/camera_status_widgets.dart';
import 'features/camera/ui/widgets/top_bar.dart';
import 'features/camera/ui/widgets/bottom_controls.dart';
import 'features/camera/ui/widgets/frame_overlay.dart';
import 'features/camera/ui/widgets/filter_selector.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  NitroConfig.instance.enable(
    slowCallThresholdMs: 200,
    level: NitroLogLevel.verbose,
  );
  NitroRuntime.init(isolatePoolSize: Platform.numberOfProcessors);

  // Pre-warm camera initialization in background after first frame draw
  Future.delayed(Duration.zero, () => CameraState.init());

  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: CameraApp()),
  );
}

class CameraApp extends StatefulWidget {
  const CameraApp({super.key});

  @override
  State<CameraApp> createState() => _CameraAppState();
}

class _CameraAppState extends State<CameraApp> with WidgetsBindingObserver {
  double _baseScale = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CameraState.init();
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
      CameraState.init();
    }
  }

  void _handleSwipe(DragEndDetails details) {
    if (details.primaryVelocity == null) return;
    final modes = ['SCANNER', 'PHOTO', 'VIDEO'];
    int currentIndex = modes.indexOf(CameraState.mode.value);
    if (details.primaryVelocity! < -300) {
      if (currentIndex < modes.length - 1) {
        CameraState.setMode(modes[currentIndex + 1]);
      }
    } else if (details.primaryVelocity! > 300) {
      if (currentIndex > 0) {
        CameraState.setMode(modes[currentIndex - 1]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sync resolution with screen aspect to avoid stretching
    final size = MediaQuery.of(context).size;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    CameraState.setResolution(
      (size.width * pixelRatio).toInt(),
      (size.height * pixelRatio).toInt(),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Watch((context) {
        final cameraPermission = CameraState.cameraPermission.value;
        if (cameraPermission != 1) {
          return PermissionGuard(
            cameraStatus: cameraPermission,
            onGrant: CameraState.grantPermission,
          );
        }

        final loading = CameraState.loading.value;
        if (loading) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.cyanAccent),
          );
        }

        return Stack(
          children: [
            // 1. Camera Preview
            Positioned.fill(
              child: GestureDetector(
                onTapUp: (details) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(details.globalPosition);

                  // Correct focus coords if using aspect ratio
                  final ar = CameraState.selectedAspectRatio.value;
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
                  CameraState.setFocusPoint(x, y);
                  CameraState.focusIndicatorTrigger.value = local;
                },
                onHorizontalDragEnd: _handleSwipe,
                onScaleStart: (_) => _baseScale = CameraState.currentZoom.value,
                onScaleUpdate: (details) {
                  final newZoom = _baseScale * details.scale;
                  if ((newZoom - CameraState.currentZoom.value).abs() > 0.05) {
                    HapticFeedback.selectionClick();
                  }
                  CameraState.setZoom(newZoom);
                },
                behavior: HitTestBehavior.opaque,
                child: Watch((context) {
                  final status = CameraState.status.value;
                  final currentDevice = CameraState.currentDevice.value;
                  final devices = CameraState.devices;
                  if (devices.isEmpty) return const SizedBox.shrink();

                  return currentDevice != null && status != CameraStatus.closed
                      ? NitraCameraPreview(
                          device: currentDevice,
                          width: CameraState.width.value,
                          height: CameraState.height.value,
                          fps: CameraState.fps.value,
                          zoom: CameraState.currentZoom.value,
                          pixelFormat: CameraState.pixelFormat.value,
                          filterShader: CameraState
                              .filters[CameraState.currentFilterName.value],
                          onStarted: (tid) {
                            CameraState.status.value = CameraStatus.running;
                            CameraState.activeTextureId.value = tid;
                          },
                          onError: (err) =>
                              CameraState.errorMessage.value = err,
                        )
                      : const Center(
                          child: Text(
                            "SELECT A CAMERA",
                            style: TextStyle(color: Colors.white24),
                          ),
                        );
                }),
              ),
            ),

            // 2b. Zoom Indicator

            // 2b. Zoom Indicator
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).size.height * 0.3,
              child: Watch((context) {
                final zoom = CameraState.currentZoom.value;
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

            // 2c. Focus Indicator
            Watch((context) {
              final offset = CameraState.focusIndicatorTrigger.value;
              if (offset == null) return const SizedBox.shrink();
              return _FocusIndicator(key: ValueKey(offset), offset: offset);
            }),

            // 3. Top Tactical Controls
            const TopBar(),

            // 4. Tactical Control Trays (Filters & Sensors)
            // 4. Tactical Control Trays (Sensors)
            const Positioned(
              bottom: 200,
              left: 0,
              right: 0,
              child: _SensorTray(),
            ),

            // 4b. Collapsible Filter Tray
            Watch((context) {
              final show = CameraState.showFilters.value;
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

            // 5. Automated Processing Layer (QR etc) - Moved here to be above tactical trays
            Watch((context) {
              final isScanner = CameraState.mode.value == 'SCANNER';
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: isScanner
                    ? FrameOverlay(
                        key: const ValueKey('scanner'),
                        isProcessing: CameraState.isProcessingFrames.value,
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              );
            }),

            // 5. Bottom Tactical Main Controls
            const BottomControls(),

            // 6. Global Overlays (Capture Flash, Rec status)
            Watch((context) {
              final trigger = CameraState.photoTrigger.value;
              if (trigger == 0) return const SizedBox.shrink();
              return _FlashOverlay(key: ValueKey(trigger));
            }),

            Watch((context) {
              if (!CameraState.isRecording.value) {
                return const SizedBox.shrink();
              }
              return const _VideoRecordingHUD();
            }),
          ],
        );
      }),
    );
  }
}

class _SensorTray extends StatelessWidget {
  const _SensorTray();

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final devices = CameraState.devices.value;
      final currentDevice = CameraState.currentDevice.value;
      if (devices.isEmpty) return const SizedBox.shrink();
      final backCameras = devices.where((d) => d.position == 1).toList();
      // Usually, lensType 1 is the 1.0x baseline.
      final baselineLens = backCameras.firstWhere(
        (d) => d.lensType == 1,
        orElse: () =>
            backCameras.isNotEmpty ? backCameras.first : devices.first,
      );
      final baselineFocal = baselineLens.focalLength;

      return Container(
        height: 60,
        margin: const EdgeInsets.only(top: 10),
        child: Center(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              mainAxisSize: MainAxisSize.min,
              children: devices.map((d) {
                final isSelected = currentDevice?.id == d.id;

                String label;
                if (d.position == 0) {
                  label = "SELF";
                } else {
                  final relZoom = d.focalLength / baselineFocal;
                  label = relZoom > 0.9 && relZoom < 1.1
                      ? "1.0"
                      : relZoom.toStringAsFixed(1);
                  if (backCameras
                          .where(
                            (e) =>
                                (e.focalLength / baselineFocal).toStringAsFixed(
                                  1,
                                ) ==
                                relZoom.toStringAsFixed(1),
                          )
                          .length >
                      1) {
                    label = "$label\nf/${d.aperture.toStringAsFixed(1)}";
                  }
                }

                return GestureDetector(
                  onTap: () => CameraState.selectDevice(d),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: isSelected ? 54 : 44,
                    height: isSelected ? 54 : 44,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.amberAccent : Colors.black45,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.white : Colors.white24,
                        width: isSelected ? 2 : 1,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: Colors.amberAccent.withValues(
                                  alpha: 0.4,
                                ),
                                blurRadius: 10,
                                spreadRadius: 2,
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white70,
                          fontSize: isSelected ? 11 : 9,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      );
    });
  }
}

class _FlashOverlay extends StatefulWidget {
  const _FlashOverlay({super.key});
  @override
  State<_FlashOverlay> createState() => _FlashOverlayState();
}

class _FlashOverlayState extends State<_FlashOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _ctrl.forward().then((_) {
      if (mounted) _ctrl.reverse();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: _ctrl,
        child: Container(color: Colors.white),
      ),
    );
  }
}

class _VideoRecordingHUD extends StatefulWidget {
  const _VideoRecordingHUD();
  @override
  State<_VideoRecordingHUD> createState() => _VideoRecordingHUDState();
}

class _VideoRecordingHUDState extends State<_VideoRecordingHUD> {
  late DateTime _startTime;
  late Timer _timer;
  String _timeStr = "00:00";

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final diff = DateTime.now().difference(_startTime);
      final m = diff.inMinutes.toString().padLeft(2, '0');
      final s = (diff.inSeconds % 60).toString().padLeft(2, '0');
      if (mounted) setState(() => _timeStr = "$m:$s");
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 120,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PulseDot(),
              const SizedBox(width: 10),
              Text(
                _timeStr,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _FocusIndicator extends StatefulWidget {
  final Offset offset;
  const _FocusIndicator({super.key, required this.offset});

  @override
  State<_FocusIndicator> createState() => _FocusIndicatorState();
}

class _FocusIndicatorState extends State<_FocusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _ctrl.forward().then((_) {
      if (CameraState.focusIndicatorTrigger.value == widget.offset) {
        CameraState.focusIndicatorTrigger.value = null;
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.offset.dx - 35,
      top: widget.offset.dy - 35,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: ReverseAnimation(_ctrl),
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 1.5),
              color: Colors.white.withValues(alpha: 0.1),
            ),
            child: const Center(
              child: Icon(
                Icons.center_focus_weak,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
