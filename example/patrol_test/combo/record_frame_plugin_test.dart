import '../test_app.dart';

void main() {
  testApp('video recording + frame-processor plugin on the same stream', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboAnalysis.recordingWithFrameProcessorPlugin();
  });
}
