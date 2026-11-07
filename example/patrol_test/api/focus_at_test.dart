import '../test_app.dart';

void main() {
  testApp('focusAt focuses with both adaptiveness modes and typed errors', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyFocusAt();
  });
}
