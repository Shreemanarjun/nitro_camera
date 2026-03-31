import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'dart:ui' as ui;
import 'package:signals_flutter/signals_flutter.dart';
import '../../state/camera_state.dart';

/// A high-performance, lifecycle-managed camera preview widget.
/// Automatically handles opening and closing the camera session.
class NitraCameraPreview extends StatefulWidget {
  final CameraDeviceInfo device;
  final int width;
  final int height;
  final int fps;
  final int pixelFormat;
  final bool enableAudio;
  final String? filterShader;
  final double zoom;
  final Function(CameraFrame)? onFrame;

  final Function(int textureId)? onStarted;
  final Function(String error)? onError;

  const NitraCameraPreview({
    super.key,
    required this.device,
    this.width = 1280,
    this.height = 720,
    this.fps = 60,
    this.pixelFormat = 1,
    this.enableAudio = false,
    this.filterShader,
    this.zoom = 1.0,
    this.onFrame,
    this.onStarted,
    this.onError,
  });

  @override
  State<NitraCameraPreview> createState() => _NitraCameraPreviewState();
}

class _NitraCameraPreviewState extends State<NitraCameraPreview> {
  bool _isSwitching = false;
  int? _textureId;
  CameraController? _controller;
  bool _isOpening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  @override
  void didUpdateWidget(NitraCameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.id != widget.device.id ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height ||
        oldWidget.fps != widget.fps ||
        oldWidget.pixelFormat != widget.pixelFormat) {
      _restartCamera();
    }
    // Logic for zoom/filter removed: handled by CameraState directly to avoid duplicates.
  }

  @override
  void dispose() {
    _closeCamera();
    super.dispose();
  }

  Future<void> _startCamera() async {
    if (_isOpening) return;
    await _openCameraInternal();
  }

  Future<void> _closeCamera() async {
    final id = _textureId;
    if (id != null) {
      _textureId = null;
      try {
        await NitroCamera.instance.closeCamera(id);
      } catch (e) {
        debugPrint("Dispose error: $e");
      }
    }
  }

  // --- Sequential Task Queue ---
  Future<void>? _nextTask;

  Future<void> _restartCamera() async {
    _nextTask = (_nextTask ?? Future.value()).then(
      (_) => _restartCameraInternal(),
    );
  }

  Future<void> _restartCameraInternal() async {
    if (!mounted) return;

    // Capture context properties BEFORE any async gaps
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final oldId = _textureId;

    setState(() {
      _isSwitching = true;
      _isOpening = true;
      _error = null;
    });

    try {
      // 1. Close old camera with timeout
      if (oldId != null) {
        try {
          await NitroCamera.instance.closeCamera(oldId);
          // Wait removed: rely on immediate hardware close + Nitro/Kotlin serial lock.
        } catch (e) {
          debugPrint("Safe close error: $e");
        }
      }

      // --- Physical Resolution Matching ---
      final physicalWidth = (widget.width * pixelRatio).toInt();
      final physicalHeight = (widget.height * pixelRatio).toInt();

      // 2. Open new session with timeout
      final id = await NitroCamera.instance.openCamera(
        widget.device.id,
        physicalWidth,
        physicalHeight,
        widget.fps,
        widget.enableAudio ? 1 : 0,
      );

      // --- Safety Delay for hardware release ---
      // Some Android chipsets (Adreno) need a moment to breathe
      // after a session close before starting a new one at a different resolution.
      await Future.delayed(const Duration(milliseconds: 200));

      if (!mounted) {
        await NitroCamera.instance.closeCamera(id);
        return;
      }

      // 3. Fire-and-forget non-blocking hardware setup to return ASAP
      NitroCamera.instance.setFrameFormat(id, widget.pixelFormat);
      if (widget.filterShader != null && widget.filterShader!.isNotEmpty) {
        NitroCamera.instance.setFilterShader(id, widget.filterShader!);
      }

      // 4. Update UI immediately once the texture is ready
      setState(() {
        _textureId = id;
        _controller = CameraController(device: widget.device)
          ..initializeWithTexture(
            id,
            physicalWidth,
            physicalHeight,
            widget.device.sensorOrientation,
          );
        _isOpening = false;
        _isSwitching = false;
      });

      widget.onStarted?.call(id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isOpening = false;
          _isSwitching = false;
          _textureId = null;
        });
      }
      widget.onError?.call(e.toString());
    }
  }

  Future<void> _openCameraInternal() async {
    await _restartCamera();
  }

  // Manual hardware setters removed: CameraState now manages these globally to avoid redundant FFI calls.

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              TextButton(
                onPressed: () async {
                  setState(() {
                    _error = null;
                  });
                  NitroCamera.instance.reset();
                  _startCamera();
                },
                child: const Text(
                  "RETRY",
                  style: TextStyle(color: Colors.cyanAccent),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 600),
      switchInCurve: Curves.easeOutQuart,
      switchOutCurve: Curves.easeInQuart,
      child: _textureId == null
          ? Container(
              key: const ValueKey('loading'),
              color: Colors.black,
              child: const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.cyanAccent,
                ),
              ),
            )
          : Watch((context) {
              return Stack(
                key: ValueKey(_textureId),
                fit: StackFit.expand,
                children: [
                  Watch((context) {
                    final ar = CameraState.selectedAspectRatio.value;
                    final mode = CameraState.previewMode.value;

                    if (_controller == null) return const SizedBox.shrink();

                    final preview = CameraPreview(
                      controller: _controller!,
                      mode: mode,
                    );

                    if (ar == null) {
                      return Positioned.fill(child: preview);
                    }
                    return Center(
                      child: AspectRatio(aspectRatio: ar, child: preview),
                    );
                  }),
                  // Overlay blur if switching
                  if (_isSwitching)
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.1),
                        ),
                      ),
                    ),

                  // Shutter Flash
                  Watch((context) {
                    final trigger = CameraState.photoTrigger.value;
                    return _ShutterFlash(trigger: trigger);
                  }),
                ],
              );
            }),
    );
  }
}

class _ShutterFlash extends StatefulWidget {
  final int trigger;
  const _ShutterFlash({required this.trigger});

  @override
  State<_ShutterFlash> createState() => _ShutterFlashState();
}

class _ShutterFlashState extends State<_ShutterFlash>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
  }

  @override
  void didUpdateWidget(_ShutterFlash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger != oldWidget.trigger) {
      _ctrl.forward(from: 0).then((_) => _ctrl.reverse());
    }
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
      child: Container(color: Colors.white),
    );
  }
}
