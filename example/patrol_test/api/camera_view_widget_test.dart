import '../test_app.dart';

void main() {
  testApp('raw CameraView widget: init, isActive toggle, double-buffered switch', ($, modules, system, apiClients) async {
    await modules.cameraWidget.verifyDeclarativeLifecycle();
  });
}
