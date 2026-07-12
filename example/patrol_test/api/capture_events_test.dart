import '../test_app.dart';

void main() {
  testApp('typed capture events arrive on events and allEvents', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyCaptureEvents();
  });
}
