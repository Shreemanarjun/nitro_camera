import '../test_app.dart';

void main() {
  testApp('encoded output error paths keep the session healthy', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyEncodedOutputErrors();
  });
}
