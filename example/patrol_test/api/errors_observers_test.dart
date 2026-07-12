import '../test_app.dart';

void main() {
  testApp('typed errors + orientation and hot-plug observer lifecycles', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyTypedErrorsAndObservers();
  });
}
