import '../test_app.dart';

void main() {
  testApp('session state + declarative configure() without a reopen', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyConfigureWithoutReopen();
  });
}
