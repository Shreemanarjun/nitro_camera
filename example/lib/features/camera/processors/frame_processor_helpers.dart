/// Composition helpers mirroring react-native-vision-camera's frame-processor
/// toolkit, adapted to Dart:
///
///  * [TargetFpsProcessor]      = VisionCamera `runAtTargetFps(fps, ...)`
///  * [AsyncFrameProcessor]     = VisionCamera `AsyncRunner.runAsync(...)`
///    (drop-latest while busy — never queue frames)
///  * [CompositeFrameProcessor] = calling multiple plugins in one processor
///
/// Best-use guidance (same spirit as VisionCamera's tips):
///  * keep the synchronous [FrameProcessor.processFrame] cheap;
///  * throttle work that doesn't need every frame with [TargetFpsProcessor];
///  * offload heavy work (ML inference etc.) with [AsyncFrameProcessor] —
///    it copies only what you extract and drops frames while busy, so the
///    camera pipeline never stalls;
///  * prefer YUV frames where possible (SCANNER mode already streams YUV) —
///    plane 0 is straight luma and much cheaper to walk than BGRA;
///  * `frame.orientation` / `frame.isMirrored` are METADATA — pixels are
///    never rotated for you. Pass the flags to your detector (ML libraries
///    accept an orientation hint) or counter-rotate in your own pipeline.
library;

import 'package:flutter/foundation.dart';
import 'package:nitro_camera/nitro_camera.dart';

import 'frame_processor.dart';

/// Runs [inner] at most [targetFps] times per second, dropping every frame
/// that arrives faster (VisionCamera `runAtTargetFps` parity). Uses the
/// frame's own capture timestamp, so throttling is exact regardless of
/// delivery jitter.
class TargetFpsProcessor extends FrameProcessor {
  final FrameProcessor inner;
  final double targetFps;
  int _lastAcceptedTs = 0;

  TargetFpsProcessor({required this.targetFps, required this.inner})
      : assert(targetFps > 0);

  @override
  String get name => '${inner.name}@${targetFps.toStringAsFixed(0)}fps';

  @override
  void onAttach(CameraController controller) => inner.onAttach(controller);

  @override
  void processFrame(CameraFrame frame) {
    final minIntervalMs = 1000 / targetFps;
    if (_lastAcceptedTs != 0 &&
        (frame.timestamp - _lastAcceptedTs) < minIntervalMs) {
      return; // drop — faster than the target rate
    }
    _lastAcceptedTs = frame.timestamp;
    inner.processFrame(frame);
  }

  @override
  void onDetach() {
    _lastAcceptedTs = 0;
    inner.onDetach();
  }
}

/// Base class for heavy processors (VisionCamera `runAsync` parity).
///
/// The zero-copy pixel buffer is only valid during the synchronous callback,
/// so asynchronous work happens in two phases:
///
///  1. [copyForAsync] — synchronous, while the buffer is valid: extract and
///     COPY exactly what the pipeline needs (e.g. a downscaled luma plane).
///  2. [processAsync] — the heavy part, run on an async context. Like
///     VisionCamera's `runAsync`, only ONE invocation runs at a time; frames
///     arriving while busy are dropped ([droppedFrames]), never queued, so a
///     500 ms model on a 60 FPS stream degrades to ~2 FPS of analysis while
///     the camera keeps rendering at full rate.
abstract class AsyncFrameProcessor<T> extends FrameProcessor {
  bool _busy = false;

  /// Frames skipped because [processAsync] was still running (diagnostics).
  int droppedFrames = 0;

  /// Whether an async invocation is currently in flight.
  bool get isBusy => _busy;

  /// Synchronously extract a COPY of the data the async phase needs. The
  /// [frame] (and its pixels) must not be retained past this call.
  T copyForAsync(CameraFrame frame);

  /// Heavy asynchronous processing of the copied [data] (isolate hand-off,
  /// ML inference, network...). Exceptions are caught and logged.
  Future<void> processAsync(T data);

  @override
  @nonVirtual
  void processFrame(CameraFrame frame) {
    if (_busy) {
      droppedFrames++;
      return;
    }
    final data = copyForAsync(frame);
    _busy = true;
    () async {
      try {
        await processAsync(data);
      } catch (e) {
        debugPrint('AsyncFrameProcessor "$name" failed: $e');
      } finally {
        _busy = false;
      }
    }();
  }
}

/// Fans one frame out to several processors (one camera stream, many
/// consumers — VisionCamera composes plugins the same way inside a single
/// frame processor). Each child is error-isolated: one throwing child never
/// starves its siblings.
class CompositeFrameProcessor extends FrameProcessor {
  final List<FrameProcessor> children;

  CompositeFrameProcessor(this.children) : assert(children.isNotEmpty);

  @override
  String get name => children.map((c) => c.name).join('+');

  @override
  void onAttach(CameraController controller) {
    for (final c in children) {
      c.onAttach(controller);
    }
  }

  @override
  void processFrame(CameraFrame frame) {
    for (final c in children) {
      try {
        c.processFrame(frame);
      } catch (e) {
        debugPrint('FrameProcessor "${c.name}" failed: $e');
      }
    }
  }

  @override
  void onDetach() {
    for (final c in children) {
      c.onDetach();
    }
  }
}
