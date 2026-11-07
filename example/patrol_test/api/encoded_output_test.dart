import '../test_app.dart';

void main() {
  testApp('encoded output (NitroCameraOutputs) feeds a hardware encoder', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyEncodedOutput();
  });
}
