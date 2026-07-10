import '../test_app.dart';

void main() {
  testApp('configure() with an fps change reopens the session', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyConfigureReopen();
  });
}
