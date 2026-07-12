import '../test_app.dart';

void main() {
  testApp('session survives rapid PHOTO VIDEO SCANNER churn', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.store.rapidModeChurnSurvives();
  });
}
