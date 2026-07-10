import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('torch + torch level on a torch-equipped device', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    final hasTorch = await modules.cameraApis.verifyTorch();
    if (!hasTorch) markTestSkipped('active device has no torch');
  });
}
