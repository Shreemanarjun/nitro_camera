import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Builds a [CameraDeviceFormat] with sensible defaults for tests.
CameraDeviceFormat fmt({
  int width = 1920,
  int height = 1080,
  double minFps = 30,
  double maxFps = 30,
  bool videoHdr = false,
  bool photoHdr = false,
  List<String> stabilization = const ['off'],
  String autoFocus = 'phase-detection',
}) {
  return CameraDeviceFormat(
    photoWidth: width,
    photoHeight: height,
    videoWidth: width,
    videoHeight: height,
    minFps: minFps,
    maxFps: maxFps,
    supportsVideoHdr: videoHdr,
    supportsPhotoHdr: photoHdr,
    videoStabilizationModes: stabilization,
    autoFocusSystem: autoFocus,
  );
}

CameraDeviceInfo device(List<CameraDeviceFormat> formats) => CameraDeviceInfo(
      id: 'back',
      name: 'Back Camera',
      position: 1,
      lensType: 1,
      sensorOrientation: 90,
      minZoom: 1,
      maxZoom: 8,
      neutralZoom: 1,
      hasFlash: true,
      hasTorch: true,
      maxPhotoWidth: 4032,
      maxPhotoHeight: 3024,
      formats: formats,
    );

void main() {
  final f720 = fmt(width: 1280, height: 720);
  final f1080 = fmt(width: 1920, height: 1080, minFps: 30, maxFps: 60);
  final f4k = fmt(width: 3840, height: 2160, minFps: 24, maxFps: 30);

  group('FormatResolver resolution rules', () {
    final dev = device([f720, f1080, f4k]);

    test('max picks the highest-resolution format', () {
      final r =
          FormatResolver.resolve(dev, const [ResolutionConstraint(TargetResolution.max())]);
      expect(r, same(f4k));
    });

    test('min picks the lowest-resolution format', () {
      final r =
          FormatResolver.resolve(dev, const [ResolutionConstraint(TargetResolution.min())]);
      expect(r, same(f720));
    });

    test('closestTo picks the nearest resolution', () {
      final r = FormatResolver.resolve(
          dev, const [ResolutionConstraint(TargetResolution.closestTo(1920, 1080))]);
      expect(r, same(f1080));
    });

    test('empty constraints default to the highest resolution', () {
      expect(FormatResolver.resolve(dev, const []), same(f4k));
      expect(dev.bestFormat(), same(f4k));
    });

    test('no formats -> null', () {
      expect(FormatResolver.resolve(device(const []), const []), isNull);
    });
  });

  group('FormatResolver feature constraints', () {
    test('fps constraint selects a format that supports the frame rate', () {
      final dev = device([f4k, f1080]); // only f1080 reaches 60fps
      final r = FormatResolver.resolve(dev, const [FpsConstraint(60)]);
      expect(r, same(f1080));
    });

    test('video-hdr constraint selects an HDR-capable format', () {
      final hdr = fmt(width: 1920, height: 1080, videoHdr: true);
      final dev = device([f4k, hdr]);
      final r = FormatResolver.resolve(dev, const [VideoHdrConstraint(true)]);
      expect(r, same(hdr));
    });
  });

  group('FormatResolver priority ordering', () {
    // Two formats, each satisfies exactly one of two competing constraints.
    final hdrOnly = fmt(videoHdr: true, stabilization: ['off']);
    final stabOnly = fmt(videoHdr: false, stabilization: ['off', 'cinematic']);
    final dev = device([hdrOnly, stabOnly]);

    test('higher-priority constraint (listed first) wins', () {
      final hdrFirst = FormatResolver.resolve(dev, const [
        VideoHdrConstraint(true),
        VideoStabilizationConstraint('cinematic'),
      ]);
      expect(hdrFirst, same(hdrOnly));

      final stabFirst = FormatResolver.resolve(dev, const [
        VideoStabilizationConstraint('cinematic'),
        VideoHdrConstraint(true),
      ]);
      expect(stabFirst, same(stabOnly));
    });
  });

  group('resolveConfig read-back', () {
    test('clamps requested fps into the selected format range', () {
      final dev = device([f1080]); // 30..60
      final resolved = FormatResolver.resolveConfig(
        dev,
        const [ResolutionConstraint(TargetResolution.closestTo(1920, 1080))],
        targetFps: 120, // above max -> clamps to 60
        requestVideoHdr: true, // but f1080 has no HDR -> disabled
      );
      expect(resolved, isNotNull);
      expect(resolved!.selectedFps, 60);
      expect(resolved.videoWidth, 1920);
      expect(resolved.videoHeight, 1080);
      expect(resolved.videoHdrEnabled, isFalse);
    });
  });
}
