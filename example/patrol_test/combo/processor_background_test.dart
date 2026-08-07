import '../test_app.dart';

void main() {
  testApp('frame-processor plugin survives background then foreground', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboAnalysis.frameProcessorSurvivesBackgrounding();
  });
}
