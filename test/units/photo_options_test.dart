// Options are constructed NON-const on purpose: a const invocation is folded at
// compile time, so the generative constructor never actually runs.
// ignore_for_file: prefer_const_constructors

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/native.dart' show PhotoOptions;
import 'package:nitro_camera/nitro_camera.dart';

/// `PhotoCaptureOptions` is the only typed surface between user code and the
/// per-capture FFI struct. A wrong bool→int polarity or a swapped enum index
/// silently changes what the camera does, so every field is pinned here.
void main() {
  group('PhotoCaptureOptions defaults', () {
    test('defaults match the documented capture behaviour', () {
      // Non-const so the generative constructor actually runs.
      final opts = PhotoCaptureOptions(flash: FlashMode.off);

      expect(opts.flash, FlashMode.off);
      expect(opts.quality, QualityPrioritization.balanced);
      expect(opts.enableShutterSound, isTrue);
      expect(opts.skipMetadata, isFalse);
      expect(opts.enableAutoRedEyeReduction, isTrue);
      expect(opts.location, isNull);
      expect(opts.outputFormat, PhotoOutputFormat.jpeg);
    });

    test('toNative() projects the defaults onto the struct', () {
      final n = PhotoCaptureOptions().toNative();

      expect(n, isA<PhotoOptions>());
      expect(n.flash, 0, reason: 'FlashMode.off');
      expect(n.qualityPrioritization, 1, reason: 'QualityPrioritization.balanced');
      expect(n.enableShutterSound, 1);
      expect(n.skipMetadata, 0);
      expect(n.enableAutoRedEyeReduction, 1);
      expect(n.hasLocation, 0);
      expect(n.latitude, 0);
      expect(n.longitude, 0);
      expect(n.altitude, 0);
      expect(n.outputFormat, 0, reason: 'PhotoOutputFormat.jpeg');
    });
  });

  group('PhotoCaptureOptions.toNative()', () {
    test('every boolean is inverted independently', () {
      final n = PhotoCaptureOptions(
        enableShutterSound: false,
        skipMetadata: true,
        enableAutoRedEyeReduction: false,
      ).toNative();

      expect(n.enableShutterSound, 0);
      expect(n.skipMetadata, 1);
      expect(n.enableAutoRedEyeReduction, 0);
      // Untouched fields keep their defaults — no cross-talk.
      expect(n.flash, 0);
      expect(n.hasLocation, 0);
    });

    test('flash maps to the FlashMode wire index at both boundaries', () {
      for (final mode in FlashMode.values) {
        expect(PhotoCaptureOptions(flash: mode).toNative().flash, mode.index);
      }
      // Pin the boundary values so a reordering of the enum is caught.
      expect(PhotoCaptureOptions(flash: FlashMode.off).toNative().flash, 0);
      expect(PhotoCaptureOptions(flash: FlashMode.auto).toNative().flash, 2);
    });

    test('quality maps to the QualityPrioritization wire index', () {
      for (final q in QualityPrioritization.values) {
        expect(
          PhotoCaptureOptions(quality: q).toNative().qualityPrioritization,
          q.index,
        );
      }
      expect(
        PhotoCaptureOptions(quality: QualityPrioritization.speed).toNative().qualityPrioritization,
        0,
      );
      expect(
        PhotoCaptureOptions(quality: QualityPrioritization.quality).toNative().qualityPrioritization,
        2,
      );
    });

    test('outputFormat maps jpeg -> 0 and dng -> 1', () {
      expect(PhotoCaptureOptions(outputFormat: PhotoOutputFormat.jpeg).toNative().outputFormat, 0);
      expect(PhotoCaptureOptions(outputFormat: PhotoOutputFormat.dng).toNative().outputFormat, 1);
      expect(PhotoOutputFormat.values, hasLength(2));
    });

    test('a location is copied verbatim and sets hasLocation', () {
      final n = PhotoCaptureOptions(
        location: (latitude: 12.5, longitude: -73.25, altitude: 431.75),
      ).toNative();

      expect(n.hasLocation, 1);
      expect(n.latitude, 12.5);
      expect(n.longitude, -73.25);
      expect(n.altitude, 431.75);
    });

    test('a null location zeroes the coordinates rather than leaking a stale geotag', () {
      final n = PhotoCaptureOptions(location: null).toNative();

      expect(n.hasLocation, 0);
      expect(n.latitude, 0);
      expect(n.longitude, 0);
      expect(n.altitude, 0);
    });

    test('a fully specified capture round-trips every field at once', () {
      final n = PhotoCaptureOptions(
        flash: FlashMode.on,
        quality: QualityPrioritization.quality,
        enableShutterSound: false,
        skipMetadata: true,
        enableAutoRedEyeReduction: false,
        location: (latitude: -1.5, longitude: 2.5, altitude: 0.5),
        outputFormat: PhotoOutputFormat.dng,
      ).toNative();

      expect(
        [
          n.flash,
          n.qualityPrioritization,
          n.enableShutterSound,
          n.skipMetadata,
          n.enableAutoRedEyeReduction,
          n.hasLocation,
          n.outputFormat,
        ],
        [1, 2, 0, 1, 0, 1, 1],
      );
      expect([n.latitude, n.longitude, n.altitude], [-1.5, 2.5, 0.5]);
    });
  });
}
