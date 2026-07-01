import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/camera_controller.dart';
import 'camera_preview.dart';

/// Declarative camera widget — the Flutter analogue of vision-camera's `<Camera>`.
///
/// `CameraView` owns the **session lifecycle** declaratively: it opens the
/// camera, and when its [device] / [width] / [height] / [fps] / [audio] props
/// change it tears the session down and reopens it (with an optional
/// [settleDelay] for hardware stability); toggling [isActive] just starts/stops
/// streaming. It hands the underlying [CameraController] to [onInitialized] so
/// you drive **controls + capture** (zoom, flash, `takePhoto`, …) imperatively —
/// high-frequency controls like zoom stay off the declarative path for
/// performance, exactly as vision-camera keeps `zoom` on a shared value.
///
/// ```dart
/// CameraView(
///   device: device,
///   width: w, height: h, fps: 60,
///   isActive: isActive,
///   onInitialized: (c) => controller = c,
/// )
/// ```
class CameraView extends StatefulWidget {
  const CameraView({
    super.key,
    required this.device,
    this.width,
    this.height,
    this.fps = 30,
    this.format,
    this.audio = false,
    this.isActive = true,
    this.previewMode = PreviewMode.texture,
    this.settleDelay = Duration.zero,
    this.loading,
    this.errorBuilder,
    this.child,
    this.onInitialized,
    this.onClosing,
    this.onConfigResolved,
    this.onEvent,
    this.onError,
  });

  /// The device to open.
  final CameraDeviceInfo device;

  /// Explicit capture resolution (e.g. screen-matched). Falls back to [format].
  final int? width;
  final int? height;

  /// Target frame rate.
  final int fps;

  /// Explicit capture format (used when [width]/[height] are not given).
  final CameraDeviceFormat? format;

  /// Capture audio for video recording. Changing this reopens the session.
  final bool audio;

  /// Whether the preview/session is running. Toggling only starts/stops it.
  final bool isActive;

  final PreviewMode previewMode;

  /// Delay between closing the old session and opening the new one on a
  /// device/resolution switch — lets the camera HAL settle on some chipsets.
  final Duration settleDelay;

  /// Widget shown while the camera initialises (defaults to a spinner).
  final Widget? loading;

  /// Builder for the error state; receives the error and a `retry` callback.
  final Widget Function(Object error, VoidCallback retry)? errorBuilder;

  /// Optional overlay rendered on top of the preview.
  final Widget? child;

  /// Called with the [CameraController] each time a session opens. Use it to
  /// drive controls + capture imperatively.
  final ValueChanged<CameraController>? onInitialized;

  /// Called right before the current session is torn down (device/resolution
  /// switch or disposal), so callers can drop their controller reference.
  final VoidCallback? onClosing;

  /// Called with the negotiated configuration (VC `onSessionConfigSelected`).
  final ValueChanged<ResolvedCameraConfig>? onConfigResolved;

  /// Called for every typed session event (started/stopped/error/interruption).
  final ValueChanged<CameraSessionEvent>? onEvent;

  /// Called if opening/reconfiguring fails, or a native `error` event arrives.
  final ValueChanged<Object>? onError;

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  CameraController? _controller;
  Object? _error;
  StreamSubscription<CameraSessionEvent>? _eventSub;

  /// Serialises open/close/restart so operations never overlap.
  Future<void> _queue = Future<void>.value();

  bool _lifecycleChanged(CameraView old) =>
      old.device.id != widget.device.id ||
      old.width != widget.width ||
      old.height != widget.height ||
      old.fps != widget.fps ||
      old.audio != widget.audio;

  @override
  void initState() {
    super.initState();
    _enqueue(_open);
  }

  @override
  void didUpdateWidget(CameraView old) {
    super.didUpdateWidget(old);
    if (_lifecycleChanged(old)) {
      _enqueue(_restart);
    } else if (old.isActive != widget.isActive) {
      _controller?.setActive(widget.isActive);
    }
  }

  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) => task()).catchError((Object e) {
      if (mounted) setState(() => _error = e);
      widget.onError?.call(e);
    });
  }

  Future<void> _open() async {
    if (!mounted) return;
    final controller = CameraController(
      device: widget.device,
      format: widget.format,
      audio: widget.audio,
    );
    await controller.initialize(
      width: widget.width,
      height: widget.height,
      fps: widget.fps,
    );
    if (!mounted) {
      await controller.dispose();
      return;
    }
    if (!widget.isActive) controller.setActive(false);
    setState(() {
      _controller = controller;
      _error = null;
    });
    widget.onInitialized?.call(controller);
    final resolved = controller.resolvedConfig;
    if (resolved != null) widget.onConfigResolved?.call(resolved);

    _eventSub?.cancel();
    _eventSub = controller.events.listen((e) {
      widget.onEvent?.call(e);
      if (e.isError) {
        final err = StateError(e.message.isEmpty ? 'camera error' : e.message);
        if (mounted) setState(() => _error = err);
        widget.onError?.call(err);
      }
    });
  }

  Future<void> _restart() async {
    await _eventSub?.cancel();
    _eventSub = null;
    final old = _controller;
    if (old != null) widget.onClosing?.call();
    if (mounted) setState(() => _controller = null);
    if (old != null) await old.dispose();
    if (widget.settleDelay > Duration.zero) {
      await Future<void>.delayed(widget.settleDelay);
    }
    await _open();
  }

  void _retry() {
    if (mounted) setState(() => _error = null);
    _enqueue(_open);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    if (_controller != null) widget.onClosing?.call();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null && widget.errorBuilder != null) {
      return widget.errorBuilder!(error, _retry);
    }
    final controller = _controller;
    if (controller == null || !controller.isInitialized) {
      return widget.loading ??
          const Center(child: CircularProgressIndicator());
    }
    return CameraPreview(
      controller: controller,
      mode: widget.previewMode,
      child: widget.child,
    );
  }
}
