import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro/nitro.dart' show nitroZeroCopyPtr;
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

  directThrowTests();

  test('direct-mode bytes are a native view a @zeroCopy param takes by pointer', () async {
    final proc = CameraFrameProcessor<bool>(isNativeView);
    await proc.start();
    final seen = <bool>[];
    final sub = proc.results.listen(seen.add);
    proc.attachDirect(oneByOneSource);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(seen, isNotEmpty);
    expect(seen, everyElement(isTrue));
    await sub.cancel();
    await proc.dispose();
  });
}

bool isNativeView(FrameData f) => nitroZeroCopyPtr(f.bytes) != null && f.bytes.first == f.timestamp;

int throwsOnOdd(FrameData f) => f.timestamp.isOdd ? throw StateError('odd') : f.timestamp;

/// Frames 1–4, one per event.
Stream<CameraFrame> oneByOneSource() => Stream.periodic(const Duration(milliseconds: 20), (i) => _frame(i + 1)).take(4);

void directThrowTests() {
  test('a throwing handler counts as a miss and the worker keeps going', () async {
    final proc = CameraFrameProcessor<int>(throwsOnOdd);
    await proc.start();
    final seen = <int>[];
    final stats = <bool>[];
    final s1 = proc.results.listen(seen.add);
    final s2 = proc.stats.listen((s) => stats.add(s.success));

    proc.attachDirect(oneByOneSource);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(seen, [2, 4]);
    expect(stats, [false, true, false, true]);
    await s1.cancel();
    await s2.cancel();
    await proc.dispose();
  });
}
