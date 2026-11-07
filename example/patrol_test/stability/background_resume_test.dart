import '../test_app.dart';

void main() {
  testApp(tags: 'slow', 'preview resumes after background then foreground', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.store.backgroundResumeSurvives();
  });
}
