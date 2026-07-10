import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

/// Builds a fake [CameraDeviceInfo] without touching any native code — the
/// model is a plain Dart class, so widget tests can drive the store directly.
CameraDeviceInfo fakeDevice({
  String id = 'back-wide',
  CameraPosition position = CameraPosition.back,
  CameraLensType lensType = CameraLensType.wideAngle,
  double focalLength = 5.0,
  bool supportsRaw = false,
  bool with4K = false,
}) {
  return CameraDeviceInfo(
    id: id,
    name: id,
    position: position,
    lensType: lensType,
    sensorOrientation: 90,
    minZoom: 1.0,
    maxZoom: 10.0,
    neutralZoom: 1.0,
    hasFlash: true,
    hasTorch: true,
    maxPhotoWidth: 4000,
    maxPhotoHeight: 3000,
    supportsRawCapture: supportsRaw,
    focalLength: focalLength,
    formats: [
      const CameraDeviceFormat(
        photoWidth: 1920,
        photoHeight: 1080,
        videoWidth: 1920,
        videoHeight: 1080,
        minFps: 1,
        maxFps: 60,
      ),
      if (with4K)
        const CameraDeviceFormat(
          photoWidth: 3840,
          photoHeight: 2160,
          videoWidth: 3840,
          videoHeight: 2160,
          minFps: 1,
          maxFps: 30,
        ),
    ],
  );
}

/// Resets the global [cameraStore] signals to their defaults. The store is
/// constructible without native calls (init() is never invoked in tests), so
/// direct signal writes are all that is needed between tests.
void resetStore() {
  cameraStore.devices.value = [];
  cameraStore.currentDevice.value = null;
  cameraStore.status.value = CameraStatus.closed;
  cameraStore.flashMode.value = FlashMode.off;
  cameraStore.previewMode.value = PreviewMode.texture;
  cameraStore.showFilters.value = false;
  cameraStore.quickSettingsOpen.value = false;
  cameraStore.rawPhoto.value = false;
  cameraStore.setFrameProcessor(null);
  cameraStore.mode.value = 'PHOTO';
  cameraStore.width.value = 1920;
  cameraStore.height.value = 1080;
  cameraStore.fps.value = 60;
  cameraStore.selectedAspectRatio.value = null;
  cameraStore.whiteBalanceKelvin.value = 0;
  cameraStore.hdrEnabled.value = false;
  cameraStore.videoStabilization.value = 0;
  cameraStore.geotagEnabled.value = false;
  cameraStore.videoCodec.value = VideoCodec.h264;
  cameraStore.currentZoom.value = 1.0;
  cameraStore.isRecording.value = false;
  cameraStore.lastCapturedPath.value = null;
  cameraStore.isLastCapturedVideo.value = false;
  cameraStore.currentFilterName.value = 'NORMAL';
  cameraStore.capturedMedia.value = const [];
  cameraStore.lastThumbnailPath.value = null;
}

/// Standard phone-sized test surface (390×844 logical), so the full quick
/// panel fits and tray offsets behave like on a real device.
void usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Minimal app shell for camera widgets (dark scaffold, no camera session).
Widget harness(Widget child) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(backgroundColor: Colors.black, body: child),
  );
}
