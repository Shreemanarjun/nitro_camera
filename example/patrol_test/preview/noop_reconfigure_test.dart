import '../test_app.dart';

void main() {
  testApp('re-applying the same config is a no-op with no stall', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifyNoOpReconfigureNoStall();
  });
}
