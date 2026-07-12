import '../test_app.dart';

void main() {
  testApp('zoom sweep keeps the preview streaming', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifyZoomSweepNoStall();
  });
}
