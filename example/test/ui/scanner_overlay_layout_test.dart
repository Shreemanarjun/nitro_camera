import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/sensor_tray.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/tray_layer.dart';

import 'test_helpers.dart';

/// Regression for the scanner UI overlap: the bottom lens tray (SensorTray:
/// BACK/FRONT + 1.0x/2.0x lens chips) rendered under the scanner overlay's
/// code-type chips (QR/1D/2D/ALL) and the two collided. In SCANNER mode the
/// tray is redundant (scanner has its own 1x/2x/3x zoom + the bottom flip
/// button) so it is hidden — which also removes the overlap. These tests pin
/// that behaviour on a real 390x844 phone surface.
void main() {
  void seedDevices() {
    cameraStore.devices.value = [
      fakeDevice(id: 'back-wide'),
      fakeDevice(id: 'front', position: CameraPosition.front),
    ];
    cameraStore.currentDevice.value = cameraStore.devices.value.first;
  }

  testWidgets('SCANNER mode hides the lens tray (no overlap possible)', (
    tester,
  ) async {
    resetStore();
    usePhoneSurface(tester);
    seedDevices();
    cameraStore.mode.value = 'SCANNER';

    await tester.pumpWidget(harness(const TrayLayer()));
    await tester.pump();

    expect(
      find.byType(SensorTray),
      findsNothing,
      reason:
          'the lens tray must be hidden in SCANNER mode so the scanner '
          'overlay owns the bottom region and nothing overlaps its code-type chips',
    );
  });

  testWidgets('non-scanner modes still show the lens tray', (tester) async {
    for (final mode in const ['PHOTO', 'VIDEO']) {
      resetStore();
      usePhoneSurface(tester);
      seedDevices();
      cameraStore.mode.value = mode;

      await tester.pumpWidget(harness(const TrayLayer()));
      await tester.pump();

      expect(
        find.byType(SensorTray),
        findsOneWidget,
        reason: 'the lens tray must still render in $mode mode',
      );
    }
  });
}
