import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('HEVC MOV recording round-trips through the typed result metadata',
      ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    final supported = await modules.cameraApis.verifyHevcRecording();
    if (!supported) markTestSkipped('device has no HEVC encoder');
  });
}
