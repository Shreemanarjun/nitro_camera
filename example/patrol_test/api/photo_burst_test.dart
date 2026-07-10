import '../test_app.dart';

void main() {
  testApp('rapid photo burst all return valid files with a live session',
      ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyPhotoBurst();
  });
}
