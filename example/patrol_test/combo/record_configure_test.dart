import '../test_app.dart';

void main() {
  testApp(
    'a resolution change mid-recording either finalises the clip or is '
    'rejected — never a truncated file or a double reopen',
    ($, modules, system, apiClients) async {
      await modules.camera.openAppToPreview();
      await modules.comboStress.configureDuringRecording();
    },
  );
}
