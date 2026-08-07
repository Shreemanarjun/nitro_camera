import 'package:nitro_camera/nitro_camera.dart';

/// Shared device / format fixtures for the `CameraController` suites.
///
/// The controller reads `device.minZoom`/`maxZoom` (clamping), `sensorOrientation`
/// and `format.videoWidth`/`videoHeight`/`maxFps` (sizing), so the fixtures make
/// those distinguishable from every default the controller falls back to.
CameraDeviceFormat testFormat({
  int width = 1280,
  int height = 720,
  double maxFps = 60,
  bool supportsVideoHdr = false,
  AutoFocusSystem autoFocusSystem = AutoFocusSystem.none,
}) => CameraDeviceFormat(
  photoWidth: width * 2,
  photoHeight: height * 2,
  videoWidth: width,
  videoHeight: height,
  minFps: 15,
  maxFps: maxFps,
  supportsVideoHdr: supportsVideoHdr,
  autoFocusSystem: autoFocusSystem,
);

CameraDeviceInfo testDevice({
  String id = 'cam0',
  double minZoom = 1.0,
  double maxZoom = 8.0,
  int sensorOrientation = 270,
  double minExposure = -4.0,
  double maxExposure = 4.0,
  List<CameraDeviceFormat> formats = const [],
}) => CameraDeviceInfo(
  id: id,
  name: 'Test Camera',
  position: CameraPosition.back,
  lensType: CameraLensType.wideAngle,
  sensorOrientation: sensorOrientation,
  minZoom: minZoom,
  maxZoom: maxZoom,
  neutralZoom: 1.0,
  hasFlash: true,
  hasTorch: true,
  maxPhotoWidth: 4032,
  maxPhotoHeight: 3024,
  minExposure: minExposure,
  maxExposure: maxExposure,
  formats: formats,
);

/// A `{"running":..,"width":..}` session-state payload for
/// `FakeNitroCamera.sessionStateJson`.
String sessionStateJson({
  bool running = true,
  int width = 1920,
  int height = 1080,
  int fps = 30,
  int pixelFormat = 0,
}) =>
    '{"running":$running,"width":$width,"height":$height,'
    '"fps":$fps,"pixelFormat":$pixelFormat}';
