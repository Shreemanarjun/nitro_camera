import '../test_app.dart';

void main() {
  testApp('recorded clips carry the requested target orientation (0 and 90)', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboRecording.recordedVideoCarriesRequestedOrientation();
  });
}
