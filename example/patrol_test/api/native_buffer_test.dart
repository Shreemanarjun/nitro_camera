import '../test_app.dart';

void main() {
  testApp('native buffers are live platform buffers, held one at a time', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyNativeBuffers();
  });
}
