import '../test_app.dart';

void main() {
  testApp(
    'illegal recorder transitions are no-ops or typed exceptions and never '
    'wedge the session',
    ($, modules, system, apiClients) async {
      await modules.camera.openAppToPreview();
      await modules.comboStress.recorderStateMachineRejectsIllegalCalls();
    },
  );
}
