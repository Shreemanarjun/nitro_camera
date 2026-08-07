import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Gap-closing tests for the isolate frame pipeline: [CameraFrameProcessor.attach]
/// (the camera-stream entry point), the stats value type, and the plugin
/// runner's stream-attached start.

// Handlers must be top-level so they can cross the isolate boundary.
Map<String, Object?> describeFrame(FrameData f) => {
  'width': f.width,
  'height': f.height,
  'format': f.format,
  'timestamp': f.timestamp,
  'orientation': f.orientation,
  'bytesPerRow': f.bytesPerRow,
  'isMirrored': f.isMirrored,
  'firstByte': f.bytes.isEmpty ? -1 : f.bytes.first,
  'length': f.bytes.length,
};

/// Records every frame it sees so the attached stream can be observed.
class CountingPlugin extends FrameProcessorPlugin {
  int seen = 0;
  CountingPlugin(super.options);

  @override
  Object? callback(FrameData frame) => {'seen': ++seen, 'width': frame.width};
}

FrameProcessorPlugin createCountingPlugin(Map<String, Object?> options) => CountingPlugin(options);

CameraFrame _cameraFrame({
  int width = 4,
  int height = 2,
  int fill = 7,
  int timestamp = 123,
  int orientation = 90,
  int bytesPerRow = 4,
  int pixelFormat = 0,
  int isMirrored = 1,
}) => CameraFrame(
  pixels: Uint8List.fromList(List.filled(width * height, fill)),
  size: width * height,
  width: width,
  height: height,
  timestamp: timestamp,
  orientation: orientation,
  textureId: 1,
  bytesPerRow: bytesPerRow,
  pixelFormat: pixelFormat,
  isMirrored: isMirrored,
);

void main() {
  group('FrameProcessStats', () {
    test('elapsedMillis converts the microsecond timing', () {
      const s = FrameProcessStats(2500, 42, success: true);
      expect(s.elapsedMillis, 2.5);
      expect(s.elapsedMicros, 2500);
      expect(s.frameTimestamp, 42);
      expect(s.success, isTrue);
      expect(const FrameProcessStats(0, 0).elapsedMillis, 0.0);
      expect(const FrameProcessStats(0, 0).success, isFalse);
    });
  });

  group('CameraFrameProcessor.attach', () {
    test('forwards every CameraFrame field to the worker handler', () async {
      final p = CameraFrameProcessor<Map<String, Object?>>(describeFrame);
      await p.start();
      final controller = StreamController<CameraFrame>();
      final sub = p.attach(controller.stream);

      final first = p.results.first;
      controller.add(_cameraFrame());
      final got = await first;

      expect(got, {
        'width': 4,
        'height': 2,
        'format': 0, // CameraFrame.pixelFormat becomes FrameData.format
        'timestamp': 123,
        'orientation': 90,
        'bytesPerRow': 4,
        'isMirrored': true, // int 1 becomes bool
        'firstByte': 7,
        'length': 8,
      });

      await sub.cancel();
      await controller.close();
      await p.dispose();
    });

    test('drop-latest: a burst never yields more results than frames sent', () async {
      final p = CameraFrameProcessor<Map<String, Object?>>(describeFrame);
      await p.start();
      final controller = StreamController<CameraFrame>();
      final sub = p.attach(controller.stream);

      final results = <Map<String, Object?>>[];
      final rsub = p.results.listen(results.add);
      for (var i = 1; i <= 20; i++) {
        controller.add(_cameraFrame(width: i, bytesPerRow: i));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(results, isNotEmpty);
      expect(results.length, lessThanOrEqualTo(20));
      // Drop-latest keeps the NEWEST pending frame, so the last width must win.
      expect(results.last['width'], 20);

      await rsub.cancel();
      await sub.cancel();
      await controller.close();
      await p.dispose();
    });

    test('cancelling the subscription detaches the stream', () async {
      final p = CameraFrameProcessor<Map<String, Object?>>(describeFrame);
      await p.start();
      final controller = StreamController<CameraFrame>.broadcast();
      final sub = p.attach(controller.stream);

      final results = <Map<String, Object?>>[];
      final rsub = p.results.listen(results.add);
      controller.add(_cameraFrame(width: 4));
      await p.stats.first;
      expect(results, hasLength(1));

      await sub.cancel();
      controller.add(_cameraFrame(width: 8));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(results, hasLength(1), reason: 'no frames after cancel');

      await rsub.cancel();
      await controller.close();
      await p.dispose();
    });

    test('frames arriving after dispose are ignored', () async {
      final p = CameraFrameProcessor<Map<String, Object?>>(describeFrame);
      await p.start();
      final controller = StreamController<CameraFrame>();
      final sub = p.attach(controller.stream);
      await p.dispose();

      // The subscription is still live; the listener must short-circuit.
      controller.add(_cameraFrame());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(p.isRunning, isFalse);

      await sub.cancel();
      await controller.close();
    });

    test('start after dispose is a StateError', () async {
      final p = CameraFrameProcessor<int>(sumLength);
      await p.start();
      await p.dispose();
      expect(p.dispose(), completes); // idempotent
      expect(() => p.start(), throwsStateError);
    });
  });

  group('FrameProcessorPluginRunner.start(frames)', () {
    test('attaches the camera stream and runs the plugin on each frame', () async {
      FrameProcessorPlugins.register('counting', createCountingPlugin);
      final runner = FrameProcessorPlugins.init('counting');
      final controller = StreamController<CameraFrame>();
      await runner.start(controller.stream);

      final results = <Object?>[];
      final sub = runner.results.listen(results.add);

      controller.add(_cameraFrame(width: 4, height: 2, bytesPerRow: 4));
      await runner.stats.first;
      controller.add(_cameraFrame(width: 4, height: 2, bytesPerRow: 4));
      await runner.stats.first;

      expect(results, hasLength(2));
      expect((results.first as Map)['seen'], 1);
      expect((results.last as Map)['seen'], 2, reason: 'same worker instance');

      // start() is idempotent: a second call must not attach a second time.
      await runner.start(controller.stream);
      controller.add(_cameraFrame(width: 4, height: 2, bytesPerRow: 4));
      await runner.stats.first;
      expect(results, hasLength(3));

      await sub.cancel();
      await controller.close();
      await runner.dispose();
    });
  });
}

int sumLength(FrameData f) => f.bytes.length;
