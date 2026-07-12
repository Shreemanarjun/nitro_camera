import '../test_app.dart';

void main() {
  testApp('typed event map routes real on-device events', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.store.eventMapRoutesRealEvents();
  });
}
