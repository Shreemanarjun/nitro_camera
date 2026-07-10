import '../test_app.dart';

void main() {
  testApp('warm device enumeration stays under the cache budget', ($, modules, system, apiClients) async {
    await modules.camera.openAppToPreview();
    await modules.performance.deviceEnumWarm();
  });
}
