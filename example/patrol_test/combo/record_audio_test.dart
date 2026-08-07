import '../test_app.dart';

void main() {
  testApp('audio:true muxes a soun track, audio:false omits it', (
    $,
    modules,
    system,
    apiClients,
  ) async {
    await modules.camera.openAppToPreview();
    await modules.comboRecording.recordingWithAudioTrack();
  });
}
