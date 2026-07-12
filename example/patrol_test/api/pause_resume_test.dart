import '../test_app.dart';

void main() {
  testApp('preview pause and resume via setActive keeps the session', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyPauseResume();
  });
}
