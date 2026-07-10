import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Boundary parse of the typed native-detector results + frame-drop reasons.
void main() {
  group('DetectionResult', () {
    test('parses a barcode payload', () {
      final r = DetectionResult.fromJson({
        'detector': 'barcode',
        'width': 1920,
        'height': 1080,
        'rotation': 90,
        'results': [
          {'text': 'HELLO', 'format': 256, 'bounds': [10, 20, 110, 220]},
        ],
      });
      expect(r, isNotNull);
      expect(r!.detector, NativeDetector.barcode);
      expect(r.frameWidth, 1920);
      expect(r.frameHeight, 1080);
      expect(r.rotation, 90);
      expect(r.faces, isEmpty);
      expect(r.barcodes.single.text, 'HELLO');
      expect(r.barcodes.single.format, 256);
      final b = r.barcodes.single.bounds!;
      expect(b.left, 10);
      expect(b.width, 100);
      expect(b.height, 200);
      final n = b.normalized(1000, 1000);
      expect(n.left, 0.01);
    });

    test('parses a face payload with optional fields', () {
      final r = DetectionResult.fromJson({
        'detector': 'face',
        'width': 640,
        'height': 480,
        'rotation': 0,
        'results': [
          {
            'bounds': [0, 0, 100, 100],
            'trackingId': 7,
            'smilingProbability': 0.9,
            'headEulerAngleY': -12.0,
            'headEulerAngleZ': 3.0,
          },
        ],
      });
      expect(r, isNotNull);
      expect(r!.detector, NativeDetector.face);
      expect(r.barcodes, isEmpty);
      final f = r.faces.single;
      expect(f.trackingId, 7);
      expect(f.smilingProbability, 0.9);
      expect(f.leftEyeOpenProbability, isNull);
      expect(f.headEulerAngleY, -12.0);
    });

    test('error / unknown-detector payloads parse to null', () {
      expect(DetectionResult.fromJson({'detector': 'barcode', 'error': 'no mlkit'}),
          isNull);
      expect(DetectionResult.fromJson({'detector': 'pose'}), isNull);
    });

    test('NativeDetector wire values', () {
      expect(NativeDetector.barcode.wire, 'barcode');
      expect(NativeDetector.face.wire, 'face');
    });
  });

  group('ThermalState', () {
    test('maps normalized levels 0..3', () {
      expect(ThermalState.fromLevel(0), ThermalState.nominal);
      expect(ThermalState.fromLevel(1), ThermalState.fair);
      expect(ThermalState.fromLevel(2), ThermalState.serious);
      expect(ThermalState.fromLevel(3), ThermalState.critical);
    });
    test('out-of-range clamps to nominal', () {
      expect(ThermalState.fromLevel(99), ThermalState.nominal);
      expect(ThermalState.fromLevel(-1), ThermalState.nominal);
    });
  });

  group('FrameDropReason', () {
    test('maps iOS reason strings', () {
      expect(FrameDropReason.fromMessage('FrameWasLate'),
          FrameDropReason.frameWasLate);
      expect(FrameDropReason.fromMessage('OutOfBuffers'),
          FrameDropReason.outOfBuffers);
      expect(FrameDropReason.fromMessage('Discontinuity'),
          FrameDropReason.discontinuity);
      expect(FrameDropReason.fromMessage('outOfBuffers'),
          FrameDropReason.outOfBuffers);
      expect(FrameDropReason.fromMessage('garbage'), FrameDropReason.unknown);
    });
  });
}
