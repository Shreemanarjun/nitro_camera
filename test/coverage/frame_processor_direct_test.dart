import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

// Top-level: handlers and frame sources run on the worker isolate.
int frameTimestamp(FrameData f) => f.timestamp;

CameraFrame _frame(int ts) => CameraFrame(
  pixels: Uint8List.fromList(List.filled(16, ts)),
  size: 16,
  width: 4,
  height: 4,
  timestamp: ts,
  orientation: 0,
  textureId: 1,
  bytesPerRow: 4,
  pixelFormat: 0,
  isMirrored: 0,
);

/// Emits a burst of three frames in one event (like a coalesced native batch),
/// then a lone fourth frame later.
Stream<CameraFrame> burstSource() {
  final c = StreamController<CameraFrame>(sync: true);
  Timer(const Duration(milliseconds: 20), () {
    c
      ..add(_frame(1))
      ..add(_frame(2))
      ..add(_frame(3));
  });
  Timer(const Duration(milliseconds: 80), () => c.add(_frame(4)));
  return c.stream;
}

void main() {
  test('attachDirect: the worker reads frames itself, newest of a burst wins', () async {
    final proc = CameraFrameProcessor<int>(frameTimestamp);
    await proc.start();
    final seen = <int>[];
    final sub = proc.results.listen(seen.add);

    proc.attachDirect(burstSource);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(seen, [3, 4], reason: 'frames 1 and 2 were stale within the burst');
    await sub.cancel();
    await proc.dispose();
  });
}
