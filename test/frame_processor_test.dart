import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/src/processing/frame_processor.dart';

// Handlers must be top-level/static so they can be sent to the worker isolate.
int sumBytes(FrameData f) => f.bytes.fold<int>(0, (a, b) => a + b);
int frameArea(FrameData f) => f.width * f.height;

void main() {
  test('processes frames on a background isolate and returns results', () async {
    final p = CameraFrameProcessor<int>(sumBytes);
    await p.start();
    expect(p.isRunning, isTrue);

    final results = <int>[];
    final sub = p.results.listen(results.add);

    p.submit(FrameData(bytes: Uint8List.fromList([1, 2, 3, 4]), width: 2, height: 2));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(results, contains(10));

    await sub.cancel();
    await p.dispose();
    expect(p.isRunning, isFalse);
  });

  test('handles a burst of frames without crashing (drop-latest)', () async {
    final p = CameraFrameProcessor<int>(frameArea);
    await p.start();

    final results = <int>[];
    final sub = p.results.listen(results.add);

    for (var i = 1; i <= 50; i++) {
      p.submit(FrameData(bytes: Uint8List(4), width: i, height: 1));
    }

    await Future<void>.delayed(const Duration(milliseconds: 200));
    // Drop-latest means we may get fewer than 50 results, but at least one, and
    // never more than were submitted.
    expect(results, isNotEmpty);
    expect(results.length, lessThanOrEqualTo(50));

    await sub.cancel();
    await p.dispose();
  });

  test('submit after dispose is a no-op', () async {
    final p = CameraFrameProcessor<int>(sumBytes);
    await p.start();
    await p.dispose();
    // Should not throw.
    p.submit(FrameData(bytes: Uint8List(1), width: 1, height: 1));
    expect(p.isRunning, isFalse);
  });
}
