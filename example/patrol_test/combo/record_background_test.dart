import '../test_app.dart';

void main() {
  testApp('recording survives backgrounding: playable clip or RecorderException', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboRecording.recordingSurvivesBackgrounding();
  });
}
