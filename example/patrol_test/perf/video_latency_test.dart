import '../test_app.dart';

void main() {
  testApp('3s video: start under 4s, stop finalises a valid file under 3s', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.performance.videoLatency();
  });
}
