import '../test_app.dart';

void main() {
  testApp('long stream keeps a stable frame rate with no degradation', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifyLongStreamStability();
  });
}
