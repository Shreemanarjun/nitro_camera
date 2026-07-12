import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/filter_selector.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/pro_strip.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/sensor_tray.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/tray_layer.dart';

import 'test_helpers.dart';

void main() {
  setUp(() {
    resetStore();
    cameraStore.photoQuality.value = QualityPrioritization.balanced;
    cameraStore.lowLightBoost.value = false;
    cameraStore.exposure.value = 0.0;
    cameraStore.torch.value = false;
    cameraStore.torchLevel.value = 1.0;
    cameraStore.samplingRate.value = 1;
    cameraStore.showFpsGraph.value = false;
  });

  Future<void> pumpStrip(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      harness(
        const Align(alignment: Alignment.bottomCenter, child: ProStrip()),
      ),
    );
    await tester.pumpAndSettle();
  }

  // Later pills can sit past the right edge of the 390-wide surface (the strip
  // scrolls horizontally) — bring them on-screen before tapping.
  Future<void> tapPill(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  group('ProStrip', () {
    testWidgets('PHOTO mode shows the photo pill set', (tester) async {
      await pumpStrip(tester);

      expect(find.text('BALANCED'), findsOneWidget); // QUALITY cycle pill
      expect(find.text('HDR'), findsOneWidget);
      expect(find.text('LOW LIGHT'), findsOneWidget);
      expect(find.text('EV 0'), findsOneWidget);
      expect(find.text('WB AUTO'), findsOneWidget);
      expect(find.text('TORCH'), findsOneWidget);

      // No scanner / video-only pills.
      expect(find.textContaining('ANALYZE'), findsNothing);
      expect(find.textContaining('STAB'), findsNothing);
      expect(find.text('GEOTAG'), findsNothing);
      expect(find.text('FPS GRAPH'), findsNothing);
    });

    testWidgets('SCANNER mode shows FPS + ANALYZE pills only', (tester) async {
      cameraStore.mode.value = 'SCANNER';
      await pumpStrip(tester);

      expect(find.text('FPS 60'), findsOneWidget);
      expect(find.text('ANALYZE 1:1'), findsOneWidget);

      expect(find.text('HDR'), findsNothing);
      expect(find.text('TORCH'), findsNothing);
      expect(find.textContaining('WB'), findsNothing);
    });

    testWidgets('VIDEO mode shows stabilize/geotag/graph plus HDR + TORCH', (
      tester,
    ) async {
      cameraStore.mode.value = 'VIDEO';
      await pumpStrip(tester);

      expect(find.text('STAB OFF'), findsOneWidget);
      expect(find.text('GEOTAG'), findsOneWidget);
      expect(find.text('FPS GRAPH'), findsOneWidget);
      expect(find.text('HDR'), findsOneWidget);
      expect(find.text('TORCH'), findsOneWidget);

      expect(find.text('LOW LIGHT'), findsNothing);
      expect(find.textContaining('ANALYZE'), findsNothing);
    });

    testWidgets('strip swaps pill sets when the mode signal changes', (
      tester,
    ) async {
      await pumpStrip(tester);
      expect(find.text('LOW LIGHT'), findsOneWidget);

      cameraStore.mode.value = 'VIDEO';
      await tester.pumpAndSettle();
      expect(find.text('LOW LIGHT'), findsNothing);
      expect(find.text('STAB OFF'), findsOneWidget);

      cameraStore.mode.value = 'SCANNER';
      await tester.pumpAndSettle();
      expect(find.text('STAB OFF'), findsNothing);
      expect(find.text('ANALYZE 1:1'), findsOneWidget);
    });

    testWidgets('QUALITY pill cycles speed → balanced → quality', (
      tester,
    ) async {
      await pumpStrip(tester);

      await tapPill(tester, find.text('BALANCED'));
      await tester.pumpAndSettle();
      expect(cameraStore.photoQuality.value, QualityPrioritization.quality);
      expect(find.text('QUALITY'), findsOneWidget);

      await tapPill(tester, find.text('QUALITY'));
      await tester.pumpAndSettle();
      expect(cameraStore.photoQuality.value, QualityPrioritization.speed);
      expect(find.text('SPEED'), findsOneWidget);

      await tapPill(tester, find.text('SPEED'));
      await tester.pumpAndSettle();
      expect(cameraStore.photoQuality.value, QualityPrioritization.balanced);
    });

    testWidgets('HDR / LOW LIGHT / WB pills drive the store', (tester) async {
      await pumpStrip(tester);

      await tapPill(tester, find.text('HDR'));
      await tester.pump();
      expect(cameraStore.hdrEnabled.value, isTrue);

      await tapPill(tester, find.text('LOW LIGHT'));
      await tester.pump();
      expect(cameraStore.lowLightBoost.value, isTrue);

      await tapPill(tester, find.text('WB AUTO'));
      await tester.pumpAndSettle();
      expect(cameraStore.whiteBalanceKelvin.value, 3000);
      expect(find.text('WB 3000K'), findsOneWidget);

      await tapPill(tester, find.text('WB 3000K'));
      await tester.pumpAndSettle();
      expect(cameraStore.whiteBalanceKelvin.value, 5500);
      expect(find.text('WB 5500K'), findsOneWidget);
    });

    testWidgets('EV pill opens the slider bubble and dragging updates the '
        'store; bubble auto-dismisses', (tester) async {
      await pumpStrip(tester);
      expect(find.byType(Slider), findsNothing);

      await tapPill(tester, find.text('EV 0'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);

      // Drag well past the 0-detent towards +EV.
      await tester.drag(find.byType(Slider), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(cameraStore.exposure.value, greaterThan(0));
      expect(find.textContaining('EV +'), findsWidgets);

      // Auto-dismisses 2.5 s after the last interaction.
      await tester.pump(const Duration(milliseconds: 2600));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('EV slider snaps to the 0 detent near neutral', (tester) async {
      cameraStore.exposure.value = 0.4;
      await pumpStrip(tester);

      await tapPill(tester, find.textContaining('EV +'));
      await tester.pumpAndSettle();

      // Drag back towards the middle — a small residual (|v| < 0.15) snaps
      // flat to exactly 0.
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(0.1);
      await tester.pumpAndSettle();
      expect(cameraStore.exposure.value, 0.0);

      // Let the auto-dismiss timer fire so no timer is pending at test end.
      await tester.pump(const Duration(milliseconds: 2600));
    });

    testWidgets('TORCH pill toggles on tap and opens the level slider on '
        'long-press', (tester) async {
      await pumpStrip(tester);

      await tapPill(tester, find.text('TORCH'));
      await tester.pumpAndSettle();
      expect(cameraStore.torch.value, isTrue);
      expect(find.text('TORCH ON'), findsOneWidget);

      await tester.ensureVisible(find.text('TORCH ON'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('TORCH ON'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);

      // Drag the level down — setTorchLevel drives both level and on/off.
      await tester.drag(find.byType(Slider), const Offset(-60, 0));
      await tester.pumpAndSettle();
      expect(cameraStore.torchLevel.value, lessThan(1.0));
      expect(cameraStore.torchLevel.value, greaterThan(0.0));
      expect(find.textContaining('TORCH '), findsWidgets);

      await tester.pump(const Duration(milliseconds: 2600));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('SAMPLING pill cycles 1 → 2 → 3 → 1', (tester) async {
      cameraStore.mode.value = 'SCANNER';
      await pumpStrip(tester);

      await tapPill(tester, find.text('ANALYZE 1:1'));
      await tester.pumpAndSettle();
      expect(cameraStore.samplingRate.value, 2);
      expect(find.text('ANALYZE 1:2'), findsOneWidget);

      await tapPill(tester, find.text('ANALYZE 1:2'));
      await tester.pumpAndSettle();
      expect(cameraStore.samplingRate.value, 3);
      expect(find.text('ANALYZE 1:3'), findsOneWidget);

      await tapPill(tester, find.text('ANALYZE 1:3'));
      await tester.pumpAndSettle();
      expect(cameraStore.samplingRate.value, 1);
      expect(find.text('ANALYZE 1:1'), findsOneWidget);
    });

    testWidgets('scanner FPS pill cycles 60 ↔ 30', (tester) async {
      cameraStore.mode.value = 'SCANNER';
      await pumpStrip(tester);

      await tapPill(tester, find.text('FPS 60'));
      await tester.pumpAndSettle();
      expect(cameraStore.fps.value, 30);
      expect(find.text('FPS 30'), findsOneWidget);
    });

    testWidgets('VIDEO pills drive stabilization / geotag / fps graph', (
      tester,
    ) async {
      cameraStore.mode.value = 'VIDEO';
      await pumpStrip(tester);

      await tapPill(tester, find.text('STAB OFF'));
      await tester.pumpAndSettle();
      expect(cameraStore.videoStabilization.value, 1);
      expect(find.text('STAB STD'), findsOneWidget);

      await tapPill(tester, find.text('STAB STD'));
      await tester.pumpAndSettle();
      expect(cameraStore.videoStabilization.value, 2);
      expect(find.text('STAB CINE'), findsOneWidget);

      await tapPill(tester, find.text('GEOTAG'));
      await tester.pump();
      expect(cameraStore.geotagEnabled.value, isTrue);

      await tapPill(tester, find.text('FPS GRAPH'));
      await tester.pump();
      expect(cameraStore.showFpsGraph.value, isTrue);
    });
  });

  group('ProStrip in TrayLayer', () {
    setUp(() {
      cameraStore.devices.value = [
        fakeDevice(
          id: 'back-wide',
          lensType: CameraLensType.wideAngle,
          focalLength: 5.0,
        ),
        fakeDevice(
          id: 'front-1',
          position: CameraPosition.front,
          focalLength: 3.0,
        ),
      ];
      cameraStore.currentDevice.value = cameraStore.devices.value.first;
    });

    testWidgets('strip is hidden while the filter tray is open — no rect '
        'overlap', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TrayLayer()));
      await tester.pumpAndSettle();

      // Closed filter tray: strip visible and live.
      final stripFinder = find.byType(ProStrip);
      AnimatedOpacity opacityOf(Finder inner) => tester.widget<AnimatedOpacity>(
        find.ancestor(of: inner, matching: find.byType(AnimatedOpacity)).first,
      );
      IgnorePointer ignoreOf(Finder inner) => tester.widget<IgnorePointer>(
        find.ancestor(of: inner, matching: find.byType(IgnorePointer)).first,
      );

      expect(opacityOf(stripFinder).opacity, 1.0);
      expect(ignoreOf(stripFinder).ignoring, isFalse);
      expect(find.text('HDR'), findsOneWidget);

      cameraStore.showFilters.value = true;
      await tester.pumpAndSettle();

      expect(opacityOf(stripFinder).opacity, 0.0);
      expect(ignoreOf(stripFinder).ignoring, isTrue);

      // The (invisible, slid-down) strip never overlaps the open filter tray.
      final stripRect = tester.getRect(stripFinder);
      final filterRect = tester.getRect(find.byType(FilterSelector));
      expect(stripRect.overlaps(filterRect), isFalse);

      // Closing the tray restores the strip.
      cameraStore.showFilters.value = false;
      await tester.pumpAndSettle();
      expect(opacityOf(stripFinder).opacity, 1.0);
      expect(ignoreOf(stripFinder).ignoring, isFalse);
    });

    testWidgets('strip does not overlap the sensor tray (lens chips)', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const TrayLayer()));
      await tester.pumpAndSettle();

      final stripRect = tester.getRect(find.byType(ProStrip));
      final sensorRect = tester.getRect(find.byType(SensorTray));
      expect(stripRect.overlaps(sensorRect), isFalse);
    });
  });
}
