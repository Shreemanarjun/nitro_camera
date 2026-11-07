import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('depth output streams metres or throws the typed unsupported error', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final supported = await modules.cameraApis.verifyDepthOutput();
    if (!supported) markTestSkipped('active camera has no depth (negative path verified)');
  });
}
