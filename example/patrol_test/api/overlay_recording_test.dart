import '../test_app.dart';

void main() {
  testApp('overlay is burned into recordings', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyOverlayInRecording();
  });
}
