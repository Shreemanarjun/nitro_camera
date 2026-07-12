import '../test_app.dart';

void main() {
  testApp('resolution change 1080p to 720p and back survives', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.store.resolutionRoundTrip();
  });
}
