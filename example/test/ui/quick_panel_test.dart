import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/top_bar.dart';

import 'test_helpers.dart';

void main() {
  setUp(resetStore);

  Future<void> openPanel(WidgetTester tester) async {
    await tester.pumpWidget(harness(const TopBar()));
    await tester.tap(find.byTooltip('Quick settings'));
    await tester.pumpAndSettle();
  }

  group('QuickPanel', () {
    testWidgets('opens and closes via the tune icon', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TopBar()));

      expect(find.text('RESOLUTION'), findsNothing);

      await tester.tap(find.byTooltip('Quick settings'));
      await tester.pumpAndSettle();
      expect(find.text('RESOLUTION'), findsOneWidget);
      expect(cameraStore.quickSettingsOpen.value, isTrue);

      await tester.tap(find.byTooltip('Quick settings'));
      await tester.pumpAndSettle();
      expect(find.text('RESOLUTION'), findsNothing);
      expect(cameraStore.quickSettingsOpen.value, isFalse);
    });

    testWidgets('shows stream rows AND the promoted settings rows',
        (tester) async {
      usePhoneSurface(tester);
      await openPanel(tester);

      // Stream config rows.
      expect(find.text('RESOLUTION'), findsOneWidget);
      expect(find.text('FPS'), findsOneWidget);
      expect(find.text('ASPECT'), findsOneWidget);

      // Promoted settings (moved out of the settings sheet).
      expect(find.text('WHITE BAL'), findsOneWidget);
      expect(find.text('HDR'), findsOneWidget);
      expect(find.text('STABILIZE'), findsOneWidget);
      expect(find.text('GEOTAG'), findsOneWidget);
      expect(find.text('CODEC'), findsOneWidget);

      // Full sheet stays reachable.
      expect(find.text('ALL SETTINGS'), findsOneWidget);
    });

    testWidgets('4K segment only appears when the sensor has a UHD format',
        (tester) async {
      usePhoneSurface(tester);
      cameraStore.currentDevice.value = fakeDevice(with4K: false);
      await openPanel(tester);
      expect(find.text('4K'), findsNothing);

      cameraStore.currentDevice.value = fakeDevice(with4K: true);
      await tester.pumpAndSettle();
      expect(find.text('4K'), findsOneWidget);
    });

    testWidgets('resolution and fps segments drive the store', (tester) async {
      usePhoneSurface(tester);
      await openPanel(tester);

      await tester.tap(find.text('720P'));
      await tester.pump();
      expect(cameraStore.width.value, 1280);
      expect(cameraStore.height.value, 720);

      await tester.tap(find.text('30'));
      await tester.pump();
      expect(cameraStore.fps.value, 30);
    });

    testWidgets('white balance presets set kelvin values', (tester) async {
      usePhoneSurface(tester);
      await openPanel(tester);

      await tester.tap(find.text('DAYLIGHT'));
      await tester.pump();
      expect(cameraStore.whiteBalanceKelvin.value, 5500);

      await tester.tap(find.text('CLOUDY'));
      await tester.pump();
      expect(cameraStore.whiteBalanceKelvin.value, 6500);

      await tester.tap(find.text('INCAND'));
      await tester.pump();
      expect(cameraStore.whiteBalanceKelvin.value, 3000);
    });

    testWidgets('HDR / geotag / stabilization / codec segments drive the store',
        (tester) async {
      usePhoneSurface(tester);
      await openPanel(tester);

      // Two ON segments exist: HDR row first, GEOTAG row second.
      await tester.tap(find.text('ON').first);
      await tester.pump();
      expect(cameraStore.hdrEnabled.value, isTrue);

      await tester.tap(find.text('ON').last);
      await tester.pump();
      expect(cameraStore.geotagEnabled.value, isTrue);

      await tester.tap(find.text('CINE'));
      await tester.pump();
      expect(cameraStore.videoStabilization.value, 2);

      await tester.tap(find.text('H.265'));
      await tester.pump();
      expect(cameraStore.videoCodec.value, VideoCodec.hevc);

      await tester.tap(find.text('H.264'));
      await tester.pump();
      expect(cameraStore.videoCodec.value, VideoCodec.h264);
    });

    testWidgets('config caption also opens the panel', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TopBar()));

      expect(find.text('1080P · 60'), findsOneWidget);
      await tester.tap(find.text('1080P · 60'));
      await tester.pumpAndSettle();
      expect(cameraStore.quickSettingsOpen.value, isTrue);
      expect(find.text('RESOLUTION'), findsOneWidget);
    });
  });
}
