import '../test_app.dart';

void main() {
  testApp('hardware detectors answer with results or a typed error', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyHardwareDetectors();
  });
}
