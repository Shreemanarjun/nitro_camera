import '../test_app.dart';

void main() {
  testApp(
    'maxDuration and maxFileSize auto-stops finalise a playable clip and '
    'leave clean recorder state behind',
    ($, modules, system, apiClients) async {
      await modules.camera.openAppToPreview();
      await modules.comboStress.recordingAutoStopLimits();
    },
  );
}
