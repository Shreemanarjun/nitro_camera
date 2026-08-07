import '../test_app.dart';

void main() {
  testApp(
    '10 back-to-back recording cycles: every clip playable, no start-latency '
    'growth, no preview FPS decay',
    ($, modules, system, apiClients) async {
      await modules.camera.openAppToPreview();
      await modules.comboStress.backToBackRecordingCycles();
    },
  );
}
