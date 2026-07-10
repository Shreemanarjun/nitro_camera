import '../test_app.dart';

void main() {
  testApp('frame processor receives frames and survives a SCANNER round-trip', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.store.processorScannerRoundTrip();
  });
}
