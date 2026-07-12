import '../test_app.dart';

void main() {
  testApp('frame-drop reasons stream is wired and typed', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifyFrameDropReasonsWired();
  });
}
