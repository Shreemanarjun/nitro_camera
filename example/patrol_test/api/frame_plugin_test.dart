import '../test_app.dart';

void main() {
  testApp('frame-processor plugin registry runs on a worker isolate', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyFrameProcessorPlugin();
  });
}
