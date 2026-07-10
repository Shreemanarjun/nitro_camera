import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('concurrent multi-cam streams keep their frame streams separate', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    final supported = await modules.cameraApis.verifyMulticamConcurrent();
    if (!supported) markTestSkipped('no concurrent combo with the active device');
  });
}
