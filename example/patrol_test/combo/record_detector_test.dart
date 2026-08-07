import '../test_app.dart';

void main() {
  testApp('video recording across mid-clip native detector churn', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboAnalysis.recordingWithNativeDetector();
  });
}
