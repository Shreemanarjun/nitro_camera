import '../test_app.dart';

void main() {
  testApp('live setters dispatch without blocking the caller', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.performance.setterLatency();
  });
}
