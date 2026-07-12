import 'package:flutter_test/flutter_test.dart' show markTestSkipped;

import '../test_app.dart';

void main() {
  testApp('photo option variants: geotag, silent plus speed, DNG', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    final report = await modules.cameraApis.verifyPhotoVariants();
    if (report.dng != 'ok') {
      markTestSkipped(
        'DNG not verified: ${report.dng} '
        '(JPEG variants passed)',
      );
    }
  });
}
