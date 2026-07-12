import '../test_app.dart';

void main() {
  testApp('every imperative live setter leaves a healthy session', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyLiveSetters();
  });
}
