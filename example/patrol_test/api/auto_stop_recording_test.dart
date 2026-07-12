import '../test_app.dart';

void main() {
  testApp(
    'maxDurationMs auto-stops and delivers the file via the stopped event',
    ($, modules, system, apiClients) async {
      await modules.camera.openAppToPreview();
      await modules.cameraApis.verifyAutoStopRecording();
    },
  );
}
