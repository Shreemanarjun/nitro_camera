import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('lens switch during recording: rejected or finalised, never broken', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final multi = await modules.comboRecording.lensSwitchDuringRecording();
    if (!multi) markTestSkipped('device exposes fewer than 2 cameras');
  });
}
