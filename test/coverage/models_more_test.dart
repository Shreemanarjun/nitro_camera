import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Gap-closing tests for the pure model layer: the event decode/dispatch
/// surface, the detection JSON parser and the device/format value types.

CameraEvent _e(int type, {int textureId = 0, int reason = 0, String message = ''}) => CameraEvent(type: type, textureId: textureId, reason: reason, message: message);

CameraSessionEvent _s(CameraEventType type, {int rawReason = 0, String message = ''}) => CameraSessionEvent(
  type: type,
  textureId: 7,
  reason: InterruptionReason.none,
  rawReason: rawReason,
  message: message,
);

void main() {
  group('CameraSessionEvent.fromNative', () {
    test('rejects a type index this plugin version does not know', () {
      final e = _e(CameraEventType.values.length);
      expect(CameraSessionEvent.isKnownType(e), isFalse);
      expect(
        () => CameraSessionEvent.fromNative(e),
        throwsA(
          isA<ArgumentError>().having((x) => x.invalidValue, 'invalidValue', CameraEventType.values.length).having((x) => x.name, 'name', 'e.type'),
        ),
      );
    });

    test('rejects a negative type index', () {
      expect(CameraSessionEvent.isKnownType(_e(-1)), isFalse);
      expect(() => CameraSessionEvent.fromNative(_e(-1)), throwsArgumentError);
    });

    test('an out-of-range reason falls back to none but keeps rawReason', () {
      final parsed = CameraSessionEvent.fromNative(
        _e(CameraEventType.orientationChanged.index, reason: 270),
      );
      expect(parsed.reason, InterruptionReason.none);
      expect(parsed.rawReason, 270);
      expect(parsed.orientationDegrees, 270);
    });
  });

  group('CameraSessionEvent accessors', () {
    test('isError / isInterruption partition the lifecycle types', () {
      expect(_s(CameraEventType.error, message: 'boom').isError, isTrue);
      expect(_s(CameraEventType.started).isError, isFalse);
      expect(_s(CameraEventType.interruptionStarted).isInterruption, isTrue);
      expect(_s(CameraEventType.interruptionEnded).isInterruption, isTrue);
      expect(_s(CameraEventType.stopped).isInterruption, isFalse);
    });

    test('frameDropReason is typed only for frameDropped events', () {
      expect(
        _s(CameraEventType.frameDropped, message: 'kCMSampleBufferDroppedFrameReason_OutOfBuffers').frameDropReason,
        FrameDropReason.outOfBuffers,
      );
      expect(
        _s(CameraEventType.frameDropped, message: 'something else entirely').frameDropReason,
        FrameDropReason.unknown,
      );
      expect(_s(CameraEventType.started, message: 'OutOfBuffers').frameDropReason, isNull);
    });

    test('thermalState is typed only for thermalStateChanged events', () {
      expect(_s(CameraEventType.thermalStateChanged, rawReason: 2).thermalState, ThermalState.serious);
      // Out-of-range levels clamp back to nominal rather than throwing.
      expect(_s(CameraEventType.thermalStateChanged, rawReason: 99).thermalState, ThermalState.nominal);
      expect(_s(CameraEventType.thermalStateChanged, rawReason: -1).thermalState, ThermalState.nominal);
      expect(_s(CameraEventType.started, rawReason: 2).thermalState, isNull);
    });

    test('deviceId is only exposed for hot-plug events', () {
      expect(_s(CameraEventType.deviceConnected, message: 'cam-1').deviceId, 'cam-1');
      expect(_s(CameraEventType.deviceDisconnected, message: 'cam-1').deviceId, 'cam-1');
      expect(_s(CameraEventType.error, message: 'cam-1').deviceId, isNull);
    });

    test('toString includes the message only when non-empty', () {
      expect(
        _s(CameraEventType.error, message: 'oops').toString(),
        'CameraSessionEvent(error, tid=7, none, "oops")',
      );
      expect(_s(CameraEventType.started).toString(), 'CameraSessionEvent(started, tid=7, none)');
    });
  });

  group('CameraSessionEvent.map', () {
    test('dispatches every branch to its typed handler', () {
      String run(CameraSessionEvent e) => e.map(
        orElse: () => 'orElse',
        started: () => 'started',
        stopped: () => 'stopped',
        error: (m) => 'error:$m',
        interruption: (r, ended) => 'interruption:${r.name}:$ended',
        orientationChanged: (d) => 'orientation:$d',
        deviceHotplug: (id, connected) => 'hotplug:$id:$connected',
        frameDropped: (r) => 'drop:${r.name}',
        thermalChanged: (s) => 'thermal:${s.name}',
        detection: (j) => 'detection:$j',
      );

      expect(run(_s(CameraEventType.started)), 'started');
      expect(run(_s(CameraEventType.stopped)), 'stopped');
      expect(run(_s(CameraEventType.error, message: 'bad')), 'error:bad');
      expect(
        run(
          const CameraSessionEvent(
            type: CameraEventType.interruptionStarted,
            textureId: 1,
            reason: InterruptionReason.audioDeviceInUseByAnotherClient,
            message: '',
          ),
        ),
        'interruption:audioDeviceInUseByAnotherClient:false',
      );
      expect(
        run(
          const CameraSessionEvent(
            type: CameraEventType.interruptionEnded,
            textureId: 1,
            reason: InterruptionReason.audioDeviceInUseByAnotherClient,
            message: '',
          ),
        ),
        'interruption:audioDeviceInUseByAnotherClient:true',
      );
      expect(run(_s(CameraEventType.orientationChanged, rawReason: 180)), 'orientation:180');
      expect(run(_s(CameraEventType.deviceConnected, message: 'a')), 'hotplug:a:true');
      expect(run(_s(CameraEventType.deviceDisconnected, message: 'a')), 'hotplug:a:false');
      expect(
        run(_s(CameraEventType.frameDropped, message: 'Discontinuity')),
        'drop:discontinuity',
      );
      expect(run(_s(CameraEventType.thermalStateChanged, rawReason: 3)), 'thermal:critical');
      expect(run(_s(CameraEventType.detection, message: '{"detector":"face"}')), 'detection:{"detector":"face"}');
    });

    test('photo-capture events have no handler slot and always hit orElse', () {
      for (final t in [
        CameraEventType.photoCaptureBegan,
        CameraEventType.photoCaptureShutter,
        CameraEventType.photoThumbnail,
      ]) {
        expect(
          _s(t).map(orElse: () => 'orElse', started: () => 'started', error: (_) => 'error'),
          'orElse',
          reason: '$t must fall through',
        );
      }
    });

    test('a missing handler falls back to orElse for every supplied branch', () {
      for (final t in CameraEventType.values) {
        expect(_s(t).map(orElse: () => 'fallback'), 'fallback');
      }
    });
  });

  group('FrameDropReason.fromMessage', () {
    test('maps the known iOS reasons and defaults to unknown', () {
      expect(FrameDropReason.fromMessage('kCMSampleBufferDroppedFrameReason_FrameWasLate'), FrameDropReason.frameWasLate);
      expect(FrameDropReason.fromMessage('kCMSampleBufferDroppedFrameReason_OutOfBuffers'), FrameDropReason.outOfBuffers);
      expect(FrameDropReason.fromMessage('Discontinuity'), FrameDropReason.discontinuity);
      expect(FrameDropReason.fromMessage(''), FrameDropReason.unknown);
      expect(FrameDropReason.fromMessage('FrameWasLate?'), isA<FrameDropReason>());
    });
  });

  group('DetectionBounds', () {
    test('geometry accessors', () {
      const b = DetectionBounds(10, 20, 30, 60);
      expect(b.width, 20);
      expect(b.height, 40);
      expect(b.centerX, 20);
      expect(b.centerY, 40);
      expect(b.toString(), 'DetectionBounds(10.0, 20.0, 30.0, 60.0)');
    });

    test('normalized divides by the frame size', () {
      const b = DetectionBounds(50, 100, 150, 300);
      final n = b.normalized(200, 400);
      expect(n.left, 0.25);
      expect(n.top, 0.25);
      expect(n.right, 0.75);
      expect(n.bottom, 0.75);
    });

    test('normalized guards against a zero frame size instead of dividing by 0', () {
      const b = DetectionBounds(1, 2, 3, 4);
      final n = b.normalized(0, 0);
      expect(n.left, 1);
      expect(n.bottom, 4);
      expect(n.left.isFinite, isTrue);
    });
  });

  group('DetectionResult.fromJson', () {
    test('an error payload yields null', () {
      expect(DetectionResult.fromJson({'error': 'no detector', 'detector': 'face'}), isNull);
    });

    test('an unknown or missing detector yields null', () {
      expect(DetectionResult.fromJson({'detector': 'pose'}), isNull);
      expect(DetectionResult.fromJson(<String, dynamic>{}), isNull);
    });

    test('barcode payload parses bounds and defaults missing fields', () {
      final r = DetectionResult.fromJson({
        'detector': 'barcode',
        'width': 640,
        'height': 480,
        'rotation': 90,
        'results': [
          {'text': 'hello', 'format': 256, 'bounds': [1, 2, 3, 4]},
          <String, dynamic>{}, // malformed entry: all fields absent
        ],
      })!;
      expect(r.detector, NativeDetector.barcode);
      expect(r.frameWidth, 640);
      expect(r.frameHeight, 480);
      expect(r.rotation, 90);
      expect(r.faces, isEmpty);
      expect(r.barcodes, hasLength(2));
      expect(r.barcodes.first.text, 'hello');
      expect(r.barcodes.first.format, 256);
      expect(r.barcodes.first.bounds!.right, 3);
      expect(r.barcodes.last.text, '');
      expect(r.barcodes.last.format, 0);
      expect(r.barcodes.last.bounds, isNull);
      expect(r.toString(), 'DetectionResult(barcode, 640x480@90°, barcodes=2, faces=0)');
    });

    test('a too-short bounds list is rejected rather than throwing', () {
      final r = DetectionResult.fromJson({
        'detector': 'barcode',
        'results': [
          {'text': 'x', 'bounds': [1, 2]},
        ],
      })!;
      expect(r.barcodes.single.bounds, isNull);
      expect(r.frameWidth, 0);
      expect(r.frameHeight, 0);
      expect(r.rotation, 0);
    });

    test('face payload parses optional probabilities and euler angles', () {
      final r = DetectionResult.fromJson({
        'detector': 'face',
        'width': 100,
        'height': 100,
        'results': [
          {
            'bounds': [0, 0, 10, 10],
            'trackingId': 4,
            'smilingProbability': 0.75,
            'leftEyeOpenProbability': 0.5,
            'rightEyeOpenProbability': 0.25,
            'headEulerAngleY': -12.5,
            'headEulerAngleZ': 3.5,
          },
          <String, dynamic>{},
        ],
      })!;
      expect(r.detector, NativeDetector.face);
      expect(r.barcodes, isEmpty);
      final f = r.faces.first;
      expect(f.trackingId, 4);
      expect(f.smilingProbability, 0.75);
      expect(f.leftEyeOpenProbability, 0.5);
      expect(f.rightEyeOpenProbability, 0.25);
      expect(f.headEulerAngleY, -12.5);
      expect(f.headEulerAngleZ, 3.5);
      final empty = r.faces.last;
      expect(empty.bounds, isNull);
      expect(empty.trackingId, isNull);
      expect(empty.smilingProbability, isNull);
      expect(empty.headEulerAngleY, 0);
      expect(empty.headEulerAngleZ, 0);
      expect(r.toString(), 'DetectionResult(face, 100x100@0°, barcodes=0, faces=2)');
    });

    test('a missing results list yields an empty detection', () {
      final r = DetectionResult.fromJson({'detector': 'barcode'})!;
      expect(r.barcodes, isEmpty);
    });

    test('NativeDetector wire values match the native contract', () {
      expect(NativeDetector.barcode.wire, 'barcode');
      expect(NativeDetector.face.wire, 'face');
    });
  });

  group('CameraDeviceInfo', () {
    CameraDeviceInfo device(CameraPosition p) => CameraDeviceInfo(
      id: 'dev-1',
      name: 'Test Cam',
      position: p,
      lensType: CameraLensType.wideAngle,
      sensorOrientation: 90,
      minZoom: 1,
      maxZoom: 8,
      neutralZoom: 1,
      hasFlash: true,
      hasTorch: true,
      maxPhotoWidth: 4032,
      maxPhotoHeight: 3024,
    );

    test('position convenience getters', () {
      expect(device(CameraPosition.back).isBackCamera, isTrue);
      expect(device(CameraPosition.back).isFrontCamera, isFalse);
      expect(device(CameraPosition.front).isFrontCamera, isTrue);
      expect(device(CameraPosition.front).isBackCamera, isFalse);
      expect(device(CameraPosition.external).isBackCamera, isFalse);
      expect(device(CameraPosition.external).isFrontCamera, isFalse);
    });

    test('toString shows id and name', () {
      expect(device(CameraPosition.back).toString(), 'CameraDeviceInfo(dev-1, Test Cam)');
    });
  });

  group('CameraDeviceFormat', () {
    test('toString shows the video resolution and max fps', () {
      const f = CameraDeviceFormat(
        photoWidth: 4032,
        photoHeight: 3024,
        videoWidth: 1920,
        videoHeight: 1080,
        minFps: 1,
        maxFps: 60,
      );
      expect(f.toString(), 'CameraDeviceFormat(1920x1080@60.0fps)');
    });
  });
}
