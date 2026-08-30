import '../test_app.dart';

void main() {
  testApp('high-speed slow-mo records or declines, session stays healthy', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyHighSpeedRecording();
  });
}
