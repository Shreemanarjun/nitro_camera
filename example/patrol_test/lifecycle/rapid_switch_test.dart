import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('survives rapid device switching (6 toggles, 1s gaps)', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final multi = await modules.store.rapidSwitchSurvives();
    if (!multi) markTestSkipped('device exposes fewer than 2 cameras');
  });
}
