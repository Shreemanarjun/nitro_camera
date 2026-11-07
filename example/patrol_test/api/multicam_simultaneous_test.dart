import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('multi-cam runs two cameras at the same time', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final supported = await modules.cameraApis.verifyTrueMulticam();
    if (!supported) markTestSkipped('no multi-cam camera pair on this device');
  });
}
