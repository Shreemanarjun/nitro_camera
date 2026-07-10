import '../test_app.dart';

void main() {
  testApp('photo right after video stop stays unstuck', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.performance.backToBackCapture();
  });
}
