import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('flash photo capture on a flash-equipped device', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    final hasFlash = await modules.cameraApis.verifyFlashPhoto();
    if (!hasFlash) markTestSkipped('active device has no flash');
  });
}
