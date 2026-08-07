import '../test_app.dart';

void main() {
  testApp('4 stills during an 8s recording, then capture still works', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboRecording.photoCaptureDuringRecording();
  });
}
