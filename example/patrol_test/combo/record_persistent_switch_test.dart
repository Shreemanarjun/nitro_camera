import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('persistent recording continues across a camera switch into one file', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final multi = await modules.comboRecording.persistentRecordingAcrossLensSwitch();
    if (!multi) markTestSkipped('device exposes fewer than 2 cameras');
  });
}
