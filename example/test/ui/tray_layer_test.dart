import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/filter_selector.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/sensor_tray.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/tray_layer.dart';

import 'test_helpers.dart';

void main() {
  setUp(() {
    resetStore();
    cameraStore.devices.value = [
      fakeDevice(
        id: 'back-wide',
        lensType: CameraLensType.wideAngle,
        focalLength: 5.0,
      ),
      fakeDevice(
        id: 'back-ultra',
        lensType: CameraLensType.ultraWideAngle,
        focalLength: 2.5,
      ),
      fakeDevice(
        id: 'front-1',
        position: CameraPosition.front,
        focalLength: 3.0,
      ),
    ];
    cameraStore.currentDevice.value = cameraStore.devices.value.first;
  });

  AnimatedOpacity opacityOf(WidgetTester tester, Finder inner) =>
      tester.widget<AnimatedOpacity>(
        find.ancestor(of: inner, matching: find.byType(AnimatedOpacity)).first,
      );

  IgnorePointer ignoreOf(WidgetTester tester, Finder inner) =>
      tester.widget<IgnorePointer>(
        find.ancestor(of: inner, matching: find.byType(IgnorePointer)).first,
      );

  group('TrayLayer', () {
    testWidgets(
      'renders BACK/FRONT tabs and lens chips including the 2× digital chip',
      (tester) async {
        usePhoneSurface(tester);
        await tester.pumpWidget(harness(const TrayLayer()));

        expect(find.text('BACK'), findsOneWidget);
        expect(find.text('FRONT'), findsOneWidget);
        expect(find.text('1.0×'), findsOneWidget);
        expect(find.text('0.5×'), findsOneWidget);
        expect(find.text('2.0×'), findsOneWidget); // digital crop chip

        // Tooltips on the chips and tabs.
        expect(find.byTooltip('Lens 1.0×'), findsOneWidget);
        expect(find.byTooltip('Lens 0.5×'), findsOneWidget);
        expect(find.byTooltip('2× digital zoom'), findsOneWidget);
        expect(find.byTooltip('Back cameras'), findsOneWidget);
        expect(find.byTooltip('Front cameras'), findsOneWidget);
      },
    );

    testWidgets('filter tray is invisible and non-interactive when closed', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TrayLayer()));
      await tester.pumpAndSettle();

      final filterFinder = find.byType(FilterSelector);
      expect(filterFinder, findsOneWidget);
      expect(opacityOf(tester, filterFinder).opacity, 0.0);
      expect(ignoreOf(tester, filterFinder).ignoring, isTrue);

      // Sensor tray is fully live.
      final sensorFinder = find.byType(SensorTray);
      expect(opacityOf(tester, sensorFinder).opacity, 1.0);
      expect(ignoreOf(tester, sensorFinder).ignoring, isFalse);
    });

    testWidgets(
      'opening the filter tray slides the sensor tray out — no rect overlap',
      (tester) async {
        usePhoneSurface(tester);
        await tester.pumpWidget(harness(const TrayLayer()));
        await tester.pumpAndSettle();

        final sensorRectClosed = tester.getRect(find.byType(SensorTray));
        final screenHeight =
            tester.view.physicalSize.height / tester.view.devicePixelRatio;
        expect(sensorRectClosed.bottom, lessThanOrEqualTo(screenHeight));

        cameraStore.showFilters.value = true;
        await tester.pumpAndSettle();

        final filterRect = tester.getRect(find.byType(FilterSelector));
        final sensorRect = tester.getRect(find.byType(SensorTray));

        // The trays never overlap while the filter tray is open.
        expect(sensorRect.overlaps(filterRect), isFalse);
        // The sensor tray is pushed fully below the screen edge.
        expect(sensorRect.top, greaterThanOrEqualTo(screenHeight));

        // Visibility and hit-testing swap with the slide.
        expect(opacityOf(tester, find.byType(FilterSelector)).opacity, 1.0);
        expect(ignoreOf(tester, find.byType(FilterSelector)).ignoring, isFalse);
        expect(opacityOf(tester, find.byType(SensorTray)).opacity, 0.0);
        expect(ignoreOf(tester, find.byType(SensorTray)).ignoring, isTrue);

        // Filter chips are shown (a couple of known filter names).
        expect(find.text('NORMAL'), findsOneWidget);
        expect(find.text('SEPIA'), findsOneWidget);

        // Closing restores the sensor tray.
        cameraStore.showFilters.value = false;
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(SensorTray)), sensorRectClosed);
      },
    );

    testWidgets('FRONT tab switches the lens chips to the selfie camera', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TrayLayer()));

      await tester.tap(find.text('FRONT'));
      await tester.pumpAndSettle();

      expect(cameraStore.currentDevice.value?.position, CameraPosition.front);
      expect(find.text('SELF'), findsOneWidget);
      expect(find.byTooltip('Selfie camera'), findsOneWidget);
    });

    testWidgets('2.0× digital chip punches zoom on the wide back camera', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TrayLayer()));

      await tester.tap(find.text('2.0×'));
      await tester.pumpAndSettle();

      expect(cameraStore.currentDevice.value?.id, 'back-wide');
      expect(cameraStore.currentZoom.value, 2.0);
    });
  });
}
