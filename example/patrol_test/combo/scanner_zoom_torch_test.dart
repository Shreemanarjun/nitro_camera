import '../test_app.dart';

void main() {
  testApp('SCANNER mode with torch on across a full zoom sweep', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboAnalysis.scannerWithZoomAndTorch();
  });
}
