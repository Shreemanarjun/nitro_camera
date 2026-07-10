import '../test_app.dart';

void main() {
  testApp('photo option variants: geotag, silent+speed, DNG', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyPhotoVariants();
  });
}
