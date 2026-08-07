import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// Gap-closing tests for the streaming [CodeScanner] façade: worker start-up,
/// per-kind handler routing, raw vs confirmed delivery, one-shot arming and
/// disposal — plus the [ScanConfirmer] paths the unit tests don't reach.

const _side = 400;

/// A [_side]×[_side] luma plane with a 240-px QR centred in it, so the
/// scanner's 0.72 viewfinder window contains the whole symbol.
Uint8List _qrPixels(String text) {
  final matrix = QRCodeWriter().encode(text, BarcodeFormat.qrCode, 240, 240);
  final bytes = Uint8List.fromList(List.filled(_side * _side, 255));
  const off = (_side - 240) ~/ 2;
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      if (matrix.get(x, y)) bytes[(y + off) * _side + x + off] = 0;
    }
  }
  return bytes;
}

CameraFrame _frame(Uint8List pixels, {int timestamp = 1}) => CameraFrame(
  pixels: pixels,
  size: pixels.length,
  width: _side,
  height: _side,
  timestamp: timestamp,
  orientation: 0,
  textureId: 1,
  bytesPerRow: _side,
  pixelFormat: 0, // YUV luma — the scanner contract
);

Uint8List _blankPixels() => Uint8List.fromList(List.filled(_side * _side, 200));

/// Pushes one frame and waits for the worker to report it (stats fire for
/// every analysed frame, hit or miss).
Future<FrameProcessStats> _pump(CodeScanner s, StreamController<CameraFrame> c, CameraFrame f) async {
  final next = s.stats.first;
  c.add(f);
  return next.timeout(const Duration(seconds: 10));
}

void main() {
  group('CodeScanner worker routing', () {
    test('every kind spawns a worker whose handler analyses the frame', () async {
      final qr = _qrPixels('kind-routing');
      for (final kind in CodeScanKind.values) {
        final scanner = CodeScanner(kind: kind);
        expect(scanner.kind, kind);
        expect(scanner.mode, ScanMode.continuous);
        expect(scanner.isArmed, isTrue);

        final controller = StreamController<CameraFrame>();
        await scanner.start(controller.stream);
        final stats = await _pump(scanner, controller, _frame(qr));

        expect(
          stats.success,
          kind == CodeScanKind.qr || kind == CodeScanKind.twoD || kind == CodeScanKind.all,
          reason: '$kind should ${kind == CodeScanKind.qr ? '' : 'not '}decode a QR',
        );
        expect(stats.elapsedMicros, greaterThanOrEqualTo(0));

        await controller.close();
        await scanner.dispose();
      }
    });
  });

  group('CodeScanner delivery', () {
    late CodeScanner scanner;
    late StreamController<CameraFrame> controller;

    tearDown(() async {
      await controller.close();
      await scanner.dispose();
    });

    test('raw detections fire per frame; confirmed results respect the streak', () async {
      scanner = CodeScanner(kind: CodeScanKind.qr, confirmationFrames: 2, cooldown: Duration.zero);
      controller = StreamController<CameraFrame>();

      final detections = <CodeResult>[];
      final confirmed = <CodeResult>[];
      final dsub = scanner.detections.listen(detections.add);
      final csub = scanner.results.listen(confirmed.add);

      await scanner.start(controller.stream);
      // A second start must be a no-op, not a second worker.
      await scanner.start(controller.stream);

      final qr = _qrPixels('streamed');
      await _pump(scanner, controller, _frame(qr));
      await pumpEventQueue();
      expect(detections.map((d) => d.text), ['streamed']);
      expect(confirmed, isEmpty, reason: 'one frame is not a confirmation');

      await _pump(scanner, controller, _frame(qr, timestamp: 2));
      await pumpEventQueue();
      expect(detections, hasLength(2));
      expect(confirmed.map((c) => c.text), ['streamed']);

      // A miss emits no detection and breaks the streak.
      await _pump(scanner, controller, _frame(_blankPixels(), timestamp: 3));
      await pumpEventQueue();
      expect(detections, hasLength(2));

      await dsub.cancel();
      await csub.cancel();
    });

    test('one-shot disarms after the first confirmation and resume re-arms', () async {
      scanner = CodeScanner(
        kind: CodeScanKind.qr,
        mode: ScanMode.oneShot,
        confirmationFrames: 1,
        cooldown: const Duration(hours: 1),
      );
      controller = StreamController<CameraFrame>();

      final confirmed = <CodeResult>[];
      final csub = scanner.results.listen(confirmed.add);
      await scanner.start(controller.stream);

      final qr = _qrPixels('one-shot');
      await _pump(scanner, controller, _frame(qr));
      await pumpEventQueue();
      expect(confirmed.map((c) => c.text), ['one-shot']);
      expect(scanner.isArmed, isFalse);

      // While disarmed, further frames must not produce results.
      await _pump(scanner, controller, _frame(qr, timestamp: 2));
      await pumpEventQueue();
      expect(confirmed, hasLength(1));

      // resume() re-arms AND clears the cooldown bookkeeping, so the same
      // payload is delivered again.
      scanner.resume();
      expect(scanner.isArmed, isTrue);
      await _pump(scanner, controller, _frame(qr, timestamp: 3));
      await pumpEventQueue();
      expect(confirmed.map((c) => c.text), ['one-shot', 'one-shot']);
      expect(scanner.isArmed, isFalse);

      await csub.cancel();
    });
  });

  test('dispose is idempotent and closes the confirmed stream', () async {
    final scanner = CodeScanner(kind: CodeScanKind.qr);
    final controller = StreamController<CameraFrame>();
    await scanner.start(controller.stream);
    await scanner.dispose();
    await scanner.dispose();
    expect(scanner.results.isBroadcast, isTrue);
    expect(await scanner.results.isEmpty, isTrue, reason: 'closed stream completes');
    await controller.close();
  });

  test('an unstarted scanner can be disposed without spawning a worker', () async {
    final scanner = CodeScanner(kind: CodeScanKind.oneD);
    expect(scanner.isArmed, isTrue);
    await scanner.dispose();
  });

  group('ScanConfirmer', () {
    test('nowMs defaults to the wall clock', () {
      final c = ScanConfirmer(confirmationFrames: 1, cooldown: const Duration(hours: 1));
      const r = CodeResult('wall-clock', CodeFormat.qrCode);
      expect(c.onFrame(r)?.text, 'wall-clock');
      // The cooldown is now armed against a real timestamp.
      expect(c.onFrame(r), isNull);
    });

    test('reset clears both the pending streak and the cooldown table', () {
      final c = ScanConfirmer(confirmationFrames: 2, cooldown: const Duration(hours: 1));
      const a = CodeResult('A', CodeFormat.qrCode);
      expect(c.onFrame(a, nowMs: 0), isNull);
      expect(c.onFrame(a, nowMs: 10)?.text, 'A');
      expect(c.onFrame(a, nowMs: 20), isNull, reason: 'still on cooldown');

      c.reset();
      // Streak restarts from zero...
      expect(c.onFrame(a, nowMs: 30), isNull);
      // ...and the cooldown no longer suppresses the payload.
      expect(c.onFrame(a, nowMs: 40)?.text, 'A');
    });
  });
}
