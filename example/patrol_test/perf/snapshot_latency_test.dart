import '../test_app.dart';

void main() {
  testApp(tags: 'slow', 'snapshot returns within 4s', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.performance.snapshotLatency();
  });
}
