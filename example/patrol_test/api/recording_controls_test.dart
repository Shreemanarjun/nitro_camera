import '../test_app.dart';

void main() {
  testApp('recording options, pause and resume, metadata and cancel', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyRecordingControls();
  });
}
