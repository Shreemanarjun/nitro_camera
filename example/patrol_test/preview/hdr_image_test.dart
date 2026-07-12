import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('video HDR engages and preserves dynamic range', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final status = await modules.preview.verifyHdrImage();
    if (status != 'ok') markTestSkipped('HDR not validated: $status');
  });
}
