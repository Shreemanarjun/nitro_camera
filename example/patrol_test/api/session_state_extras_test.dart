import '../test_app.dart';

void main() {
  testApp('session state reports colour range and audio availability', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    modules.cameraApis.verifySessionStateExtras();
  });
}
