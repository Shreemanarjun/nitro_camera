import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';
import 'controller_fixtures.dart';

/// A recording can end WITHOUT Dart asking: `maxDurationMs` / `maxFileSizeBytes`
/// auto-stops and encoder failures are finalised natively and only announced
/// through the event stream.
///
/// Before the fix, nothing cleared `CameraController._isRecording` outside
/// `stopRecording()` / `cancelRecording()`, so `isRecording` stayed `true`
/// indefinitely and any UI bound to it kept showing a live recording. Caught on
/// a real OnePlus CPH2447 by `example/patrol_test/combo/record_auto_stop_test.dart`
/// ("controller.isRecording stayed TRUE for 3s after the native
/// maxDurationReached auto-stop").
void main() {
  late FakeNitroCamera fake;
  late CameraController controller;

  setUp(() async {
    fake = FakeNitroCamera();
    controller = CameraController(device: testDevice(), native: fake);
    await controller.initialize();
  });

  tearDown(() async {
    await controller.dispose();
    await fake.close();
  });

  Future<void> startRecording() async {
    await controller.startRecording('/tmp/clip.mp4');
    expect(controller.isRecording, isTrue);
  }

  test('a native stopped event clears recording state', () async {
    await startRecording();

    fake.emitEvent(
      CameraEventType.stopped.index,
      textureId: controller.textureId!,
      message: '/tmp/clip.mp4',
    );
    await pumpEventQueue();

    expect(
      controller.isRecording,
      isFalse,
      reason: 'a native auto-stop must clear isRecording — otherwise the app '
          'shows a live recording that already ended',
    );
    expect(controller.isRecordingPaused, isFalse);
  });

  test('a native error event clears recording state', () async {
    await startRecording();

    fake.emitEvent(
      CameraEventType.error.index,
      textureId: controller.textureId!,
      message: 'recording failed: MediaRecorder error 1/-1007',
    );
    await pumpEventQueue();

    expect(controller.isRecording, isFalse);
  });

  test('listeners are notified so a recording UI can rebuild', () async {
    await startRecording();
    var notifications = 0;
    controller.addListener(() => notifications++);

    fake.emitEvent(
      CameraEventType.stopped.index,
      textureId: controller.textureId!,
    );
    await pumpEventQueue();

    expect(notifications, greaterThan(0));
  });

  test('a stopped event for a DIFFERENT session is ignored', () async {
    await startRecording();

    fake.emitEvent(CameraEventType.stopped.index, textureId: 9999);
    await pumpEventQueue();

    expect(
      controller.isRecording,
      isTrue,
      reason: 'another session ending must not cancel this one',
    );
  });

  test('a stopped event while not recording is inert', () async {
    var notifications = 0;
    controller.addListener(() => notifications++);

    fake.emitEvent(
      CameraEventType.stopped.index,
      textureId: controller.textureId!,
    );
    await pumpEventQueue();

    expect(controller.isRecording, isFalse);
    expect(notifications, 0, reason: 'no state changed, so no rebuild');
  });

  test('an explicit stopRecording still reports the native result', () async {
    await startRecording();
    final result = await controller.stopRecording();

    expect(result.path, fake.recordingResult.path);
    expect(controller.isRecording, isFalse);
  });
}
