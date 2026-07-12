import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('4K switch keeps a live preview and reports a real 4K stream', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final has4k = await modules.store.fourKRoundTrip();
    if (!has4k) markTestSkipped('active sensor advertises no 4K format');
  });
}
