import '../test_app.dart';

void main() {
  testApp('camera extensions on, still, off', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyCameraExtensions();
  });
}
