import '../test_app.dart';

void main() {
  testApp('detector start and stop churn keeps the stream alive', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyDetectorChurn();
  });
}
