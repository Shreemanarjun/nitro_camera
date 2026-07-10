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
    this.resizeMode = PreviewResizeMode.cover,
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

  /// How the preview fills its box — cover (crop) or contain (letterbox).
  final PreviewResizeMode resizeMode;

  /// On a same-device reopen (resolution / fps / audio change): delay between
  /// closing the old session and opening the new one — lets the camera HAL
  /// settle on some chipsets. On a **device switch** (double-buffered swap):
  /// how long the new session gets to render its first frames before the
  /// frozen old preview is dropped.
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

  /// During a device-switch double-buffered swap: the OLD controller, kept
  /// alive (and its preview mounted, frozen on the last frame) while the NEW
  /// session opens and renders behind it. Disposed only after the swap.
  CameraController? _retiring;

  Object? _error;
  StreamSubscription<CameraSessionEvent>? _eventSub;

  /// Serialises open/close/restart so operations never overlap.
  Future<void> _queue = Future<void>.value();

  /// Bumped for every enqueued lifecycle op — an in-flight open's retry/backoff
  /// loop aborts when a newer op (device switch, restart) supersedes it.
  int _epoch = 0;

  /// Bounded open retry policy: exponential backoff 250ms → 4s, then give up
  /// into the error state (the [CameraView.errorBuilder] retry restarts it).
  /// Never hammer a failing camera service in a tight loop — a wedged HAL
  /// (OnePlus "unknown device" storms) needs idle time to recover.
  static const int _maxOpenAttempts = 5;
  static const Duration _initialRetryDelay = Duration(milliseconds: 250);
  static const Duration _maxRetryDelay = Duration(seconds: 4);

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
      // A device change uses the double-buffered swap (the old preview stays
      // visible until the new session renders); same-device reopens
      // (resolution / fps / audio change) tear down first, as before.
      final deviceChanged = old.device.id != widget.device.id;
      _enqueue(() => _restart(doubleBuffered: deviceChanged));
    } else if (old.isActive != widget.isActive) {
      _controller?.setActive(widget.isActive);
    }
  }

  void _enqueue(Future<void> Function() task) {
    _epoch++;
    _queue = _queue.then((_) => task()).catchError((Object e) {
      if (mounted) setState(() => _error = e);
      widget.onError?.call(e);
    });
  }

  /// Opens the camera with a bounded exponential-backoff retry. Gives up (and
  /// surfaces the last error) after [_maxOpenAttempts], or immediately when
  /// the widget unmounts / a newer lifecycle op is enqueued.
  Future<void> _open() async {
    final epoch = _epoch;
    var delay = _initialRetryDelay;
    for (var attempt = 1; ; attempt++) {
      if (!mounted || epoch != _epoch) return;
      try {
        await _openOnce();
        return;
      } catch (e) {
        if (attempt >= _maxOpenAttempts || !mounted || epoch != _epoch) {
          rethrow;
        }
        debugPrint('CameraView: open attempt $attempt/$_maxOpenAttempts '
            'failed ($e) — retrying in ${delay.inMilliseconds}ms');
        await Future<void>.delayed(delay);
        delay *= 2;
        if (delay > _maxRetryDelay) delay = _maxRetryDelay;
      }
    }
  }

  Future<void> _openOnce() async {
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
        final err = SessionException.nativeError(e.message);
        // An error EVENT while a live controller is still streaming is
        // recoverable/transient (heavy-format transitions, e.g. 4K, emit a
        // generic AVFoundation error that the session survives) — replacing a
        // WORKING preview with the errorBuilder here is exactly the
        // "switched resolution → no preview" bug. Keep the preview mounted;
        // surface the error through onError. Only a missing controller
        // (session actually gone) flips the view into its error state.
        if (_controller == null && mounted) setState(() => _error = err);
        widget.onError?.call(err);
      }
    });
  }

  Future<void> _restart({required bool doubleBuffered}) async {
    await _eventSub?.cancel();
    _eventSub = null;
    final old = _controller;
    if (old != null) widget.onClosing?.call();

    if (!doubleBuffered || old == null) {
      // Teardown-first reopen (same device, new resolution / fps / audio).
      if (mounted) setState(() => _controller = null);
      if (old != null) await old.dispose();
      if (widget.settleDelay > Duration.zero) {
        await Future<void>.delayed(widget.settleDelay);
      }
      await _open();
      return;
    }

    // DEVICE SWITCH — freeze-frame swap. The old controller's texture stays
    // MOUNTED (frozen on its last rendered frame) while the new session opens
    // and renders behind it, closing the black gap between teardown and the
    // new session's first frame. But the old camera HARDWARE is closed FIRST:
    // two briefly-overlapping open cameras wedge constrained HALs (OnePlus
    // storms "unknown device" errors from the camera service for every id).
    // The frozen frame survives the close because the native side keeps the
    // Flutter texture registered until after the swap window
    // (NitraCameraSession.closeKeepTexture + deferred releaseTexture).
    _retiring = old;
    if (mounted) {
      setState(() => _controller = null);
    } else {
      _controller = null;
    }
    try {
      await old.closeSession();
      await _open();
      // The new preview mounts (behind the old frame) as soon as _open
      // publishes the controller; give it [settleDelay] to render its first
      // frames before the frozen old preview is dropped.
      if (mounted && widget.settleDelay > Duration.zero) {
        await Future<void>.delayed(widget.settleDelay);
      }
    } finally {
      final retiring = _retiring;
      _retiring = null;
      if (retiring != null) {
        if (mounted) {
          setState(() {});
          // Let the frame that unmounts the old preview render before its
          // native texture is released, so a disposed textureId is never on
          // screen (stale-textureId guard).
          await WidgetsBinding.instance.endOfFrame;
        }
        await retiring.dispose();
      }
    }
  }

  void _retry() {
    if (mounted) setState(() => _error = null);
    _enqueue(_open);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    if (_controller != null || _retiring != null) widget.onClosing?.call();
    _controller?.dispose();
    _retiring?.dispose();
    _retiring = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null && widget.errorBuilder != null) {
      return widget.errorBuilder!(error, _retry);
    }
    final controller = _controller;
    final active =
        (controller != null && controller.isInitialized) ? controller : null;
    final retiring = _retiring;

    final Widget child;
    if (active == null && retiring == null) {
      child = KeyedSubtree(
        key: const ValueKey('nitra_camera_loading'),
        child: widget.loading ??
            const Center(child: CircularProgressIndicator()),
      );
    } else {
      // ONE stable 'live' subtree hosts every running-preview state, so a
      // double-buffered device swap only reshuffles the keyed previews INSIDE
      // it (no AnimatedSwitcher cross-fade, never a frame without a mounted
      // texture), while loading <-> live transitions still cross-fade. Each
      // preview is keyed on its own textureId: Texture/AndroidView must be
      // recreated per session (stale-textureId guard).
      child = KeyedSubtree(
        key: const ValueKey('nitra_camera_live'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (active != null)
              KeyedSubtree(
                key: ValueKey('nitra_preview_${active.textureId}'),
                child: CameraPreview(
                  controller: active,
                  mode: widget.previewMode,
                  resizeMode: widget.resizeMode,
                ),
              ),
            // The retiring preview sits ON TOP, frozen on its last frame,
            // while the new session warms up beneath it (double-buffered
            // device switch). Distinct key namespace + identity guard: a
            // failed open can leave both slots with the same textureId
            // (e.g. null), which would be a duplicate-key red screen.
            if (retiring != null &&
                !identical(retiring, active) &&
                retiring.textureId != active?.textureId)
              KeyedSubtree(
                key: ValueKey('nitra_retiring_${retiring.textureId}'),
                child: CameraPreview(
                  controller: retiring,
                  mode: widget.previewMode,
                  resizeMode: widget.resizeMode,
                ),
              ),
            if (widget.child != null) widget.child!,
          ],
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );
  }
}
