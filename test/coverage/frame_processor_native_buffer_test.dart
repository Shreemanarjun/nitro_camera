import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Native-buffer ownership in [CameraFrameProcessor]: every held buffer goes
/// back to the camera exactly once — after the handler, when a frame is
/// dropped (drop-latest), before the worker is ready, and on dispose. A leak
/// would stop native buffers for good (one is held at a time).

const _portName = 'native-buffer-releases';

// Top-level: releasers and handlers run on the worker isolate in direct mode.
void recordRelease(int handle) => IsolateNameServer.lookupPortByName(_portName)!.send(handle);

int bufferOf(FrameData f) => f.nativeBuffer;

int slowBufferOf(FrameData f) {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < 60) {}
  return f.nativeBuffer;
}

CameraFrame _frame(int buffer, {int ts = 0}) => CameraFrame(
  pixels: Uint8List(16),
  size: 16,
  width: 4,
  height: 4,
  timestamp: ts,
  orientation: 0,
  textureId: 1,
  bytesPerRow: 4,
  pixelFormat: 0,
  isMirrored: 0,
  nativeBuffer: buffer,
);

void main() {
  late ReceivePort releases;
  late List<int> released;

  setUp(() {
    released = [];
    releases = ReceivePort()..listen((h) => released.add(h as int));
    IsolateNameServer.removePortNameMapping(_portName);
    IsolateNameServer.registerPortWithName(releases.sendPort, _portName);
  });

  tearDown(() {
    IsolateNameServer.removePortNameMapping(_portName);
    releases.close();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

  test('attach: the handler sees the buffer, then it is released once', () async {
    final proc = CameraFrameProcessor<int>(bufferOf, releaseBuffer: recordRelease);
    await proc.start();
    final seen = <int>[];
    final sub = proc.results.listen(seen.add);
    final frames = StreamController<CameraFrame>();
    final att = proc.attach(frames.stream);

    frames.add(_frame(101));
    await settle();
    frames.add(_frame(102));
    await settle();

    expect(seen, [101, 102]);
    expect(released, [101, 102]);
    await att.cancel();
    await sub.cancel();
    await proc.dispose();
    await settle();
    expect(released, [101, 102], reason: 'no double release on dispose');
  });

  test('attach: frames without a buffer release nothing', () async {
    final proc = CameraFrameProcessor<int>(bufferOf, releaseBuffer: recordRelease);
    await proc.start();
    final frames = StreamController<CameraFrame>();
    final att = proc.attach(frames.stream);
    frames
      ..add(_frame(0))
      ..add(_frame(0));
    await settle();
    expect(released, isEmpty);
    await att.cancel();
    await proc.dispose();
  });

  test('attach: a dropped (replaced) pending frame is released too', () async {
    final proc = CameraFrameProcessor<int>(slowBufferOf, releaseBuffer: recordRelease);
    await proc.start();
    final seen = <int>[];
    final sub = proc.results.listen(seen.add);
    final frames = StreamController<CameraFrame>(sync: true);
    final att = proc.attach(frames.stream);

    frames
      ..add(_frame(1)) // in flight
      ..add(_frame(2)) // pending, then replaced
      ..add(_frame(3)); // pending
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(seen, [1, 3]);
    expect(released..sort(), [1, 2, 3], reason: 'every buffer exactly once');
    await att.cancel();
    await sub.cancel();
    await proc.dispose();
  });

  test('attach: dispose releases the in-flight and pending buffers', () async {
    final proc = CameraFrameProcessor<int>(slowBufferOf, releaseBuffer: recordRelease);
    await proc.start();
    final frames = StreamController<CameraFrame>(sync: true);
    proc.attach(frames.stream);
    frames
      ..add(_frame(7))
      ..add(_frame(8));
    await proc.dispose();
    await settle();
    expect(released..sort(), [7, 8]);
  });

  test('attach before the worker is ready releases instead of leaking', () async {
    final proc = CameraFrameProcessor<int>(bufferOf, releaseBuffer: recordRelease);
    final frames = StreamController<CameraFrame>(sync: true);
    final att = proc.attach(frames.stream);
    frames.add(_frame(55));
    await settle();
    expect(released, [55]);
    await att.cancel();
    await proc.dispose();
  });

  test('attachDirect: burst — stale frames and handled frames are all released', () async {
    final proc = CameraFrameProcessor<int>(bufferOf, releaseBuffer: recordRelease);
    await proc.start();
    final seen = <int>[];
    final sub = proc.results.listen(seen.add);
    proc.attachDirect(burstWithBuffers);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(seen, [13, 14], reason: 'newest of the burst, then the lone frame');
    expect(released..sort(), [11, 12, 13, 14]);
    await sub.cancel();
    await proc.dispose();
  });
}

/// Three frames in one burst, then a lone fourth (runs on the worker).
Stream<CameraFrame> burstWithBuffers() {
  final c = StreamController<CameraFrame>(sync: true);
  Timer(const Duration(milliseconds: 20), () {
    c
      ..add(_frame(11))
      ..add(_frame(12))
      ..add(_frame(13));
  });
  Timer(const Duration(milliseconds: 80), () => c.add(_frame(14)));
  return c.stream;
}
