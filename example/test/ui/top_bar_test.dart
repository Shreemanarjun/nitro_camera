import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/top_bar.dart';

import 'test_helpers.dart';

void main() {
  setUp(resetStore);

  group('TopBar icon strip', () {
    testWidgets('renders every icon control with a tooltip', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TopBar()));

      expect(find.byTooltip('Flash: off'), findsOneWidget);
      expect(find.byTooltip('Filters'), findsOneWidget);
      expect(find.byTooltip('Preview engine'), findsOneWidget);
      expect(find.byTooltip('Frame processor (demo)'), findsOneWidget);
      expect(find.byTooltip('Quick settings'), findsOneWidget);
      expect(find.byTooltip('Stream configuration'), findsOneWidget);
    });

    testWidgets('RAW badge is hidden when the sensor lacks RAW support', (
      tester,
    ) async {
      usePhoneSurface(tester);
      cameraStore.currentDevice.value = fakeDevice(supportsRaw: false);
      await tester.pumpWidget(harness(const TopBar()));

      expect(find.byTooltip('RAW capture (DNG)'), findsNothing);
      expect(find.text('RAW'), findsNothing);
    });

    testWidgets('RAW badge appears when the sensor supports RAW', (
      tester,
    ) async {
      usePhoneSurface(tester);
      cameraStore.currentDevice.value = fakeDevice(supportsRaw: true);
      await tester.pumpWidget(harness(const TopBar()));

      expect(find.byTooltip('RAW capture (DNG)'), findsOneWidget);
      expect(find.text('RAW'), findsOneWidget);

      await tester.tap(find.byTooltip('RAW capture (DNG)'));
      await tester.pump();
      expect(cameraStore.rawPhoto.value, isTrue);
    });

    testWidgets('flash icon cycles off → on → auto and the tooltip follows', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TopBar()));

      await tester.tap(find.byTooltip('Flash: off'));
      await tester.pump();
      expect(cameraStore.flashMode.value, FlashMode.on);
      expect(find.byTooltip('Flash: on'), findsOneWidget);

      await tester.tap(find.byTooltip('Flash: on'));
      await tester.pump();
      expect(cameraStore.flashMode.value, FlashMode.auto);
      expect(find.byTooltip('Flash: auto'), findsOneWidget);
    });

    testWidgets('long-press shows the tooltip without firing the tap action', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TopBar()));

      expect(cameraStore.showFilters.value, isFalse);
      await tester.longPress(find.byTooltip('Filters'));
      await tester.pump();

      // Tooltip balloon is visible and the filters toggle did NOT fire.
      expect(find.text('Filters'), findsOneWidget);
      expect(cameraStore.showFilters.value, isFalse);

      // Let the tooltip auto-dismiss so no timers leak out of the test.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('filters icon toggles the filter tray signal', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TopBar()));

      await tester.tap(find.byTooltip('Filters'));
      await tester.pump();
      expect(cameraStore.showFilters.value, isTrue);

      await tester.tap(find.byTooltip('Filters'));
      await tester.pump();
      expect(cameraStore.showFilters.value, isFalse);
    });
  });
}
