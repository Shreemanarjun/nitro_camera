import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('synchronized output pairs each frame with its depth map', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final supported = await modules.cameraApis.verifySynchronizedOutput();
    if (!supported) markTestSkipped('no camera with depth on this device');
  });
}
