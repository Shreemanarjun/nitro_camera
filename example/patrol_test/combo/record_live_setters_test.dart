import '../test_app.dart';

void main() {
  testApp('zoom, torch and exposure storm during a 6s recording', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboRecording.liveSettersDuringRecording();
  });
}
