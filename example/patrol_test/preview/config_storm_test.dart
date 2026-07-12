import '../test_app.dart';

void main() {
  testApp('preview survives a live config storm without stalling', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifyConfigStormNoStall();
  });
}
