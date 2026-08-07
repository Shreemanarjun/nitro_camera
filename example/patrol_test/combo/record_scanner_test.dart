import '../test_app.dart';

void main() {
  testApp('video recording from inside SCANNER mode', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboAnalysis.recordingWhileScanning();
  });
}
