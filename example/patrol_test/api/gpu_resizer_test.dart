import '../test_app.dart';

void main() {
  testApp('GPU resizer streams ML tensors', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyGpuResizer();
  });
}
