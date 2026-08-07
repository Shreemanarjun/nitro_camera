import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

const _format = CameraDeviceFormat(
  photoWidth: 4032,
  photoHeight: 3024,
  videoWidth: 1920,
  videoHeight: 1080,
  minFps: 1,
  maxFps: 60,
  supportsVideoHdr: true,
  autoFocusSystem: AutoFocusSystem.phaseDetection,
);

ResolvedCameraConfig _config({
  int videoWidth = 1920,
  int videoHeight = 1080,
  int selectedFps = 30,
  bool videoHdrEnabled = false,
  PixelFormat pixelFormat = PixelFormat.yuv420,
  AutoFocusSystem autoFocusSystem = AutoFocusSystem.phaseDetection,
}) => ResolvedCameraConfig(
  format: _format,
  selectedFps: selectedFps,
  videoWidth: videoWidth,
  videoHeight: videoHeight,
  photoWidth: 4032,
  photoHeight: 3024,
  videoHdrEnabled: videoHdrEnabled,
  pixelFormat: pixelFormat,
  autoFocusSystem: autoFocusSystem,
);

/// `ResolvedCameraConfig` is what the UI reads back to learn what the camera
/// *actually* chose, so every accessor is part of the contract.
void main() {
  group('ResolvedCameraConfig', () {
    test('holds every negotiated value it was constructed with', () {
      final c = _config(videoHdrEnabled: true, pixelFormat: PixelFormat.bgra);

      expect(identical(c.format, _format), isTrue);
      expect(c.selectedFps, 30);
      expect(c.videoWidth, 1920);
      expect(c.videoHeight, 1080);
      expect(c.photoWidth, 4032);
      expect(c.photoHeight, 3024);
      expect(c.videoHdrEnabled, isTrue);
      expect(c.pixelFormat, PixelFormat.bgra);
      expect(c.autoFocusSystem, AutoFocusSystem.phaseDetection);
    });

    test('aspectRatio is the VIDEO ratio, not the photo ratio', () {
      // Photo is 4:3 here; the preview must not inherit it.
      expect(_config().aspectRatio, closeTo(16 / 9, 1e-12));
      expect(_config(videoWidth: 640, videoHeight: 480).aspectRatio, closeTo(4 / 3, 1e-12));
    });

    test('aspectRatio is 0 when the height is unknown instead of dividing by zero', () {
      final c = _config(videoWidth: 1920, videoHeight: 0);

      expect(c.aspectRatio, 0);
      expect(c.aspectRatio.isFinite, isTrue);
    });

    test('toString reports resolution, fps, hdr and pixel format', () {
      final s = _config(
        selectedFps: 24,
        videoHdrEnabled: true,
        pixelFormat: PixelFormat.bgra,
      ).toString();

      expect(s, 'ResolvedCameraConfig(1920x1080@24fps, hdr=true, pixelFormat=bgra)');
    });

    test('toString reflects a non-HDR yuv420 session', () {
      expect(
        _config(videoWidth: 1280, videoHeight: 720, selectedFps: 60).toString(),
        'ResolvedCameraConfig(1280x720@60fps, hdr=false, pixelFormat=yuv420)',
      );
    });
  });
}
