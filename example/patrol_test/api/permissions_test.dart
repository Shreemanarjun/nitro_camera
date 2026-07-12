import '../test_app.dart';

void main() {
  testApp('permission APIs agree with the granted state', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyPermissionApis();
  });
}
