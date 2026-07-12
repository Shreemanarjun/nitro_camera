import '../test_app.dart';

void main() {
  testApp('preview sustains frames without lag or stall', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifySustainedPreview();
  });
}
