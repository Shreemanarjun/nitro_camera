import '../test_app.dart';

void main() {
  testApp('native detector on and off keeps frames flowing', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyNativeDetectorSmoke();
  });
}
