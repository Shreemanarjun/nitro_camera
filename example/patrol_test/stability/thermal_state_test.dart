import '../test_app.dart';

void main() {
  testApp(tags: 'slow', 'device thermal state is published on open', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.store.thermalStatePublished();
  });
}
