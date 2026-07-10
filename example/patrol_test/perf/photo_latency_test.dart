import '../test_app.dart';

void main() {
  testApp('photo capture returns within 4s, three times in a row', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.performance.photoLatency();
  });
}
