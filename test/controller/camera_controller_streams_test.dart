import 'dart:convert' show jsonEncode;

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';
import 'controller_fixtures.dart';

/// The controller's derived streams: session-id filtering, version-skew
/// tolerance, and the typed projections layered on the raw event stream.
void main() {
  late FakeNitroCamera fake;
  late CameraController c;

  setUp(() async {
    fake = FakeNitroCamera();
    c = CameraController(device: testDevice(), native: fake);
    await c.initialize();
    fake.clear();
  });

  tearDown(() async {
    await c.dispose();
    await fake.close();
  });

  /// Collects everything [stream] emits while [emit] runs.
  Future<List<T>> collect<T>(Stream<T> stream, void Function() emit) async {
    final seen = <T>[];
    final sub = stream.listen(seen.add);
    emit();
    await pumpEventQueue();
    await sub.cancel();
    return seen;
  }

  group('events', () {
    test('keeps this session and the broadcast (textureId 0) events', () async {
      final seen = await collect(c.events, () {
        fake.emitEvent(CameraEventType.started.index, textureId: 7);
        fake.emitEvent(CameraEventType.stopped.index, textureId: 0);
      });

      expect(seen.map((e) => e.type), [
        CameraEventType.started,
        CameraEventType.stopped,
      ]);
      expect(seen.first.textureId, 7);
    });

    test('drops events belonging to another session', () async {
      final seen = await collect(c.events, () {
        fake.emitEvent(CameraEventType.started.index, textureId: 99);
      });

      expect(seen, isEmpty);
    });

    test('skips type indices this plugin version does not know', () async {
      final seen = await collect(c.events, () {
        fake.emitEvent(999, textureId: 7);
        fake.emitEvent(-1, textureId: 7);
        fake.emitEvent(CameraEventType.started.index, textureId: 7);
      });

      expect(
        seen.map((e) => e.type),
        [CameraEventType.started],
        reason: 'version skew must not kill the stream',
      );
    });

    test('decodes the interruption reason and the error message', () async {
      final seen = await collect(c.events, () {
        fake.emitEvent(
          CameraEventType.interruptionStarted.index,
          textureId: 7,
          reason: InterruptionReason.videoDeviceInUseByAnotherClient.index,
        );
        fake.emitEvent(
          CameraEventType.error.index,
          textureId: 7,
          message: 'HAL died',
        );
      });

      expect(seen, hasLength(2));
      expect(
        seen[0].reason,
        InterruptionReason.videoDeviceInUseByAnotherClient,
      );
      expect(seen[0].isInterruption, isTrue);
      expect(seen[1].isError, isTrue);
      expect(seen[1].message, 'HAL died');
    });
  });

  group('allEventsOf', () {
    test('emits every session without a textureId filter', () async {
      final seen = await collect(CameraController.allEventsOf(fake), () {
        fake.emitEvent(CameraEventType.started.index, textureId: 7);
        fake.emitEvent(CameraEventType.stopped.index, textureId: 4242);
      });

      expect(seen.map((e) => e.textureId), [7, 4242]);
    });

    test('still skips unknown type indices', () async {
      final seen = await collect(CameraController.allEventsOf(fake), () {
        fake.emitEvent(CameraEventType.values.length, textureId: 7);
        fake.emitEvent(CameraEventType.started.index, textureId: 7);
      });

      expect(seen.map((e) => e.type), [CameraEventType.started]);
    });
  });

  group('frameStream', () {
    test('only delivers this session\'s frames', () async {
      final seen = await collect(c.frameStream, () {
        fake.emitFrame(textureId: 7, width: 8, height: 4);
        fake.emitFrame(textureId: 8, width: 2, height: 2);
        fake.emitFrame(textureId: 0, width: 1, height: 1);
      });

      expect(seen, hasLength(1), reason: 'no cross-session leakage');
      expect(seen.single.width, 8);
      expect(seen.single.height, 4);
      expect(seen.single.pixels, hasLength(32));
    });
  });

  group('nativeDetections', () {
    test('decodes the JSON payload of detection events', () async {
      final payload = jsonEncode({
        'detector': 'barcode',
        'width': 1920,
        'height': 1080,
        'rotation': 90,
        'results': [
          {'text': 'HELLO', 'format': 256},
        ],
      });

      final seen = await collect(c.nativeDetections, () {
        fake.emitEvent(
          CameraEventType.detection.index,
          textureId: 7,
          message: payload,
        );
      });

      expect(seen.single['detector'], 'barcode');
      expect(seen.single['results'], hasLength(1));
    });

    test('malformed JSON yields an error map instead of killing the stream',
        () async {
      final seen = await collect(c.nativeDetections, () {
        fake.emitEvent(
          CameraEventType.detection.index,
          textureId: 7,
          message: '{not json',
        );
        fake.emitEvent(
          CameraEventType.detection.index,
          textureId: 7,
          message: '"a bare string"',
        );
      });

      expect(seen, [
        {'error': 'bad detection payload'},
        {'error': 'bad detection payload'},
      ]);
    });

    test('ignores other event types and other sessions', () async {
      final seen = await collect(c.nativeDetections, () {
        fake.emitEvent(CameraEventType.started.index, textureId: 7);
        fake.emitEvent(
          CameraEventType.detection.index,
          textureId: 99,
          message: '{"detector":"face"}',
        );
      });

      expect(seen, isEmpty);
    });
  });

  group('detections', () {
    test('maps decodable payloads to the typed result', () async {
      final seen = await collect(c.detections, () {
        fake.emitEvent(
          CameraEventType.detection.index,
          textureId: 7,
          message: jsonEncode({
            'detector': 'face',
            'width': 640,
            'height': 480,
            'rotation': 0,
            'results': [
              {
                'bounds': [0, 0, 100, 100],
                'trackingId': 3,
              },
            ],
          }),
        );
      });

      expect(seen.single.detector, NativeDetector.face);
      expect(seen.single.frameWidth, 640);
      expect(seen.single.frameHeight, 480);
      expect(seen.single.faces.single.trackingId, 3);
    });

    test('drops payloads that do not parse to a result', () async {
      final seen = await collect(c.detections, () {
        // Malformed -> {'error': ...} -> DetectionResult.fromJson returns null.
        fake.emitEvent(
          CameraEventType.detection.index,
          textureId: 7,
          message: 'garbage',
        );
        // An unrecognised detector also parses to null.
        fake.emitEvent(
          CameraEventType.detection.index,
          textureId: 7,
          message: '{"detector":"pose"}',
        );
      });

      expect(seen, isEmpty);
    });
  });

  group('frameDropReasons', () {
    test('types the drop-reason message of this session', () async {
      final seen = await collect(c.frameDropReasons, () {
        fake.emitEvent(
          CameraEventType.frameDropped.index,
          textureId: 7,
          message: 'FrameWasLate',
        );
        fake.emitEvent(
          CameraEventType.frameDropped.index,
          textureId: 7,
          message: 'OutOfBuffers',
        );
        fake.emitEvent(
          CameraEventType.frameDropped.index,
          textureId: 7,
          message: 'something new',
        );
        fake.emitEvent(CameraEventType.started.index, textureId: 7);
        fake.emitEvent(
          CameraEventType.frameDropped.index,
          textureId: 99,
          message: 'FrameWasLate',
        );
      });

      expect(seen, [
        FrameDropReason.frameWasLate,
        FrameDropReason.outOfBuffers,
        FrameDropReason.unknown,
      ]);
    });
  });

  group('thermalStates', () {
    test('maps the thermal level of every thermal event', () async {
      final seen = await collect(c.thermalStates, () {
        fake.emitEvent(CameraEventType.thermalStateChanged.index, reason: 0);
        fake.emitEvent(
          CameraEventType.thermalStateChanged.index,
          textureId: 7,
          reason: 2,
        );
        fake.emitEvent(CameraEventType.thermalStateChanged.index, reason: 3);
        fake.emitEvent(CameraEventType.thermalStateChanged.index, reason: 42);
        fake.emitEvent(CameraEventType.started.index, textureId: 7);
      });

      expect(seen, [
        ThermalState.nominal,
        ThermalState.serious,
        ThermalState.critical,
        ThermalState.nominal,
      ]);
    });
  });
}
