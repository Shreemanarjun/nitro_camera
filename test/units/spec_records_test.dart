// ignore_for_file: prefer_const_constructors
//
// The constructors under test are `const`. A const invocation is folded at
// compile time and never executes, so a const call covers nothing — these must
// stay non-const for the constructor bodies to run. Do not `dart fix` this file.

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/src/nitro_camera.native.dart';

void main() {
  group('CameraDevice spec record', () {
    test('defaults fill the optional fields', () {
      final d = CameraDevice(
        id: 'back-0',
        name: 'Back Camera',
        position: 1,
        sensorOrientation: 90,
        maxZoom: 8.0,
        neutralZoom: 1.0,
        hasFlash: 1,
        hasTorch: 1,
        maxPhotoWidth: 4032,
        maxPhotoHeight: 3024,
        focalLength: 4.7,
        aperture: 1.8,
      );

      expect(d.id, 'back-0');
      expect(d.name, 'Back Camera');
      expect(d.position, 1);
      expect(d.sensorOrientation, 90);
      expect(d.maxZoom, 8.0);
      // Documented defaults — a change here silently alters device selection
      // and zoom clamping for every caller that omits them.
      expect(d.lensType, 0);
      expect(d.minZoom, 1.0);
    });

    test('explicit values override the defaults', () {
      final d = CameraDevice(
        id: 'ultra-wide',
        name: 'Ultra Wide',
        position: 1,
        lensType: 2,
        sensorOrientation: 270,
        minZoom: 0.5,
        maxZoom: 4.0,
        neutralZoom: 1.0,
        hasFlash: 0,
        hasTorch: 0,
        maxPhotoWidth: 1920,
        maxPhotoHeight: 1080,
        focalLength: 1.9,
        aperture: 2.2,
      );

      expect(d.lensType, 2);
      expect(d.minZoom, 0.5);
      expect(d.sensorOrientation, 270);
      expect(d.hasFlash, 0);
      expect(d.hasTorch, 0);
    });
  });
}
