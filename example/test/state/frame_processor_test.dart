import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera_example/features/camera/processors/frame_processor.dart';
import 'package:nitro_camera_example/features/camera/processors/frame_processor_helpers.dart';
import 'package:nitro_camera_example/features/camera/processors/luminance_processor.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

/// Minimal user-side implementation of the [FrameProcessor] interface —
/// records lifecycle calls and received frames.
class RecordingProcessor implements FrameProcessor {
  final frames = <CameraFrame>[];
  int attachCount = 0;
  int detachCount = 0;
  bool throwOnFrame = false;

  @override
  String get name => 'REC';

  @override
  void onAttach(CameraController controller) => attachCount++;

  @override
  void processFrame(CameraFrame frame) {
    if (throwOnFrame) throw StateError('boom');
    frames.add(frame);
  }

  @override
  void onDetach() => detachCount++;
}

CameraFrame fakeFrame({
  int width = 4,
  int height = 4,
  int pixelFormat = 1, // BGRA
  int fill = 128,
  int? timestamp,
}) {
  final bpp = pixelFormat == 1 ? 4 : 1;
  return CameraFrame(
    pixels: Uint8List.fromList(List.filled(width * height * bpp, fill)),
    size: width * height * bpp,
    width: width,
    height: height,
    timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
    orientation: 0,
    textureId: 1,
    bytesPerRow: width * bpp,
    pixelFormat: pixelFormat,
  );
}

void main() {
  setUp(() {
    cameraStore.mode.value = 'PHOTO';
    cameraStore.setFrameProcessor(null);
    cameraStore.isProcessingFrames.value = false;
  });

  group('FrameProcessor plumbing', () {
    test('setFrameProcessor installs the processor and clear detaches it', () {
      final p = RecordingProcessor();
      cameraStore.setFrameProcessor(p);
      expect(cameraStore.frameProcessor.value, same(p));
      // No live session in unit tests — onAttach waits for one.
      expect(p.attachCount, 0);
      expect(p.detachCount, 0);

      cameraStore.clearFrameProcessor();
      expect(cameraStore.frameProcessor.value, isNull);
      expect(p.detachCount, 1);
    });

    test('replacing a processor detaches the previous one', () {
      final first = RecordingProcessor();
      final second = RecordingProcessor();
      cameraStore.setFrameProcessor(first);
      cameraStore.setFrameProcessor(second);

      expect(first.detachCount, 1);
      expect(second.detachCount, 0);
      expect(cameraStore.frameProcessor.value, same(second));

      // Setting the same instance again is a no-op (no spurious detach).
      cameraStore.setFrameProcessor(second);
      expect(second.detachCount, 0);

      cameraStore.setFrameProcessor(null);
    });

    test('handleFrame routes frames to the active processor', () {
      final p = RecordingProcessor();
      cameraStore.setFrameProcessor(p);

      final frame = fakeFrame();
      cameraStore.handleFrame(frame);
      cameraStore.handleFrame(frame);
      expect(p.frames.length, 2);

      cameraStore.setFrameProcessor(null);
      cameraStore.handleFrame(frame);
      expect(p.frames.length, 2, reason: 'cleared processor gets no frames');
    });

    test('a throwing processor never breaks the frame pipeline', () {
      final p = RecordingProcessor()..throwOnFrame = true;
      cameraStore.setFrameProcessor(p);

      expect(() => cameraStore.handleFrame(fakeFrame()), returnsNormally);

      // The pipeline keeps delivering after the failure.
      p.throwOnFrame = false;
      cameraStore.handleFrame(fakeFrame());
      expect(p.frames.length, 1);

      cameraStore.setFrameProcessor(null);
    });

    test('processor survives SCANNER mode round-trips (coexists with the '
        'Dart scanner)', () async {
      final p = RecordingProcessor();
      cameraStore.setFrameProcessor(p);

      await cameraStore.setMode('SCANNER');
      expect(cameraStore.frameProcessor.value, same(p));
      expect(p.detachCount, 0);

      await cameraStore.setMode('PHOTO');
      expect(cameraStore.frameProcessor.value, same(p));
      expect(p.detachCount, 0);

      cameraStore.setFrameProcessor(null);
    });
  });

  group('LuminanceFrameProcessor (reference implementation)', () {
    test('estimates mean luminance from BGRA frames', () {
      final p = LuminanceFrameProcessor();

      p.processFrame(fakeFrame(fill: 255)); // white
      expect(p.luminance.value, closeTo(1.0, 0.02));

      p.processFrame(fakeFrame(fill: 0)); // black
      expect(p.luminance.value, closeTo(0.0, 0.02));

      p.processFrame(fakeFrame(fill: 128)); // mid grey
      expect(p.luminance.value, closeTo(0.5, 0.05));
    });

    test('reads plane-0 luma for YUV frames and resets on detach', () {
      final p = LuminanceFrameProcessor();

      p.processFrame(fakeFrame(pixelFormat: 0, fill: 255));
      expect(p.luminance.value, closeTo(1.0, 0.02));

      p.onDetach();
      expect(p.luminance.value, 0.0);
      expect(p.attached.value, isFalse);
    });
  });

  group('TargetFpsProcessor (runAtTargetFps parity)', () {
    test('drops frames arriving faster than the target rate', () {
      final inner = RecordingProcessor();
      final p = TargetFpsProcessor(targetFps: 30, inner: inner);
      expect(p.name, 'REC@30fps');

      // 30 fps => min 33.3 ms between accepted frames.
      p.processFrame(fakeFrame(timestamp: 1000)); // accepted (first)
      p.processFrame(fakeFrame(timestamp: 1010)); // +10ms — dropped
      p.processFrame(fakeFrame(timestamp: 1020)); // +20ms — dropped
      p.processFrame(fakeFrame(timestamp: 1040)); // +40ms — accepted
      p.processFrame(fakeFrame(timestamp: 1050)); // +10ms — dropped
      p.processFrame(fakeFrame(timestamp: 1100)); // +60ms — accepted

      expect(inner.frames.map((f) => f.timestamp), [1000, 1040, 1100]);
    });

    test('forwards lifecycle and resets throttling on detach', () {
      final inner = RecordingProcessor();
      final p = TargetFpsProcessor(targetFps: 30, inner: inner);

      p.processFrame(fakeFrame(timestamp: 1000));
      p.onDetach();
      expect(inner.detachCount, 1);

      // After a detach the throttle window restarts — an "early" frame from
      // a new session is accepted again.
      p.processFrame(fakeFrame(timestamp: 1001));
      expect(inner.frames.length, 2);
    });
  });

  group('AsyncFrameProcessor (runAsync parity)', () {
    test('copies synchronously, runs one async job at a time, drops while '
        'busy', () async {
      final p = _GatedAsyncProcessor();

      p.processFrame(fakeFrame(fill: 7)); // starts the async job
      expect(p.copies.length, 1);
      expect(p.isBusy, isTrue);

      p.processFrame(fakeFrame(fill: 8)); // busy — dropped
      p.processFrame(fakeFrame(fill: 9)); // busy — dropped
      expect(p.copies.length, 1);
      expect(p.droppedFrames, 2);

      p.gate.complete(); // finish the in-flight job
      await Future<void>.delayed(Duration.zero);
      expect(p.isBusy, isFalse);

      p.processFrame(fakeFrame(fill: 10)); // accepted again
      expect(p.copies.length, 2);
      expect(p.copies.last.first, 10);

      p.gate = Completer<void>()..complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('an async failure frees the context for the next frame', () async {
      final p = _GatedAsyncProcessor();

      p.processFrame(fakeFrame());
      p.gate.completeError(StateError('model crashed'));
      await Future<void>.delayed(Duration.zero);
      expect(p.isBusy, isFalse);

      p.gate = Completer<void>();
      p.processFrame(fakeFrame());
      expect(p.copies.length, 2);
      p.gate.complete();
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('CompositeFrameProcessor', () {
    test('fans frames and lifecycle out to every child, error-isolated', () {
      final a = RecordingProcessor();
      final b = RecordingProcessor()..throwOnFrame = true;
      final c = RecordingProcessor();
      final p = CompositeFrameProcessor([a, b, c]);
      expect(p.name, 'REC+REC+REC');

      expect(() => p.processFrame(fakeFrame()), returnsNormally);
      expect(a.frames.length, 1);
      expect(
        c.frames.length,
        1,
        reason: 'a throwing sibling must not starve later children',
      );

      p.onDetach();
      expect(a.detachCount, 1);
      expect(b.detachCount, 1);
      expect(c.detachCount, 1);
    });
  });

  group('Processor profiling (fps / avg ms)', () {
    test('publishes fps and mean cost once a 1 s frame window closes, and '
        'resets when the processor changes', () {
      final p = RecordingProcessor();
      cameraStore.setFrameProcessor(p);
      expect(cameraStore.processorFps.value, 0.0);

      // 25 frames spaced 50 ms apart: window closes at +1200 ms.
      for (var i = 0; i <= 24; i++) {
        cameraStore.handleFrame(fakeFrame(timestamp: 5000 + i * 50));
      }
      expect(cameraStore.processorFps.value, greaterThan(0));
      expect(cameraStore.processorFps.value, closeTo(20, 3));
      expect(cameraStore.processorAvgMs.value, greaterThanOrEqualTo(0));

      cameraStore.setFrameProcessor(null);
      expect(cameraStore.processorFps.value, 0.0);
      expect(cameraStore.processorAvgMs.value, 0.0);
    });
  });
}

/// [AsyncFrameProcessor] test double whose async phase is gated on a
/// [Completer], so tests control exactly when the context frees up.
class _GatedAsyncProcessor extends AsyncFrameProcessor<Uint8List> {
  final copies = <Uint8List>[];
  Completer<void> gate = Completer<void>();

  @override
  String get name => 'GATED';

  @override
  Uint8List copyForAsync(CameraFrame frame) {
    final copy = Uint8List.fromList(frame.pixels);
    copies.add(copy);
    return copy;
  }

  @override
  Future<void> processAsync(Uint8List data) => gate.future;
}
