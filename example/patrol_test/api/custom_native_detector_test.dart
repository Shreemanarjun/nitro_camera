import '../test_app.dart';

void main() {
  testApp('custom registered native detector (meanLuma) delivers results', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyCustomNativeDetector();
  });
}
