import '../test_app.dart';

void main() {
  testApp('frameStream delivers only its own session frames', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyFrameStreamContract();
  });
}
