import '../test_app.dart';

void main() {
  testApp('app boots to a running camera preview', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.camera.verifyPreviewHealthy();
  });
}
