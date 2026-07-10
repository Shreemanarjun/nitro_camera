import '../test_app.dart';

void main() {
  testApp('thermal state arrives on the controller stream', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifyThermalViaControllerStream();
  });
}
