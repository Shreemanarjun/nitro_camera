import '../test_app.dart';

void main() {
  testApp('filtered recording, filtered stills and two filter switches', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboRecording.filteredRecordingAndStills();
  });
}
