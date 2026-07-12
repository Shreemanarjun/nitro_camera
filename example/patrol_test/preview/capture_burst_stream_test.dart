import '../test_app.dart';

void main() {
  testApp('capture burst keeps the preview live', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.preview.verifyCaptureBurstDuringStream();
  });
}
