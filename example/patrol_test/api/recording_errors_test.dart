import '../test_app.dart';

void main() {
  testApp('recording error paths surface typed errors and recover',
      ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyRecordingErrorPaths();
  });
}
