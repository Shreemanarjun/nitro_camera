import '../test_app.dart';

void main() {
  testApp('store-level capture persists and survives the gallery mirror', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.store.captureAndPersist();
  });
}
