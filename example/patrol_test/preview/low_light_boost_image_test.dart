import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('low-light boost brightens the image without breaking the stream', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final supported = await modules.preview.verifyLowLightBoostImage();
    if (!supported) markTestSkipped('device has no low-light boost');
  });
}
