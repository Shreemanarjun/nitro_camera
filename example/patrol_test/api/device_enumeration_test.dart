import '../test_app.dart';

void main() {
  testApp('typed device enumeration, selectors and format resolver', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.cameraApis.verifyTypedDeviceEnumeration();
  });
}
