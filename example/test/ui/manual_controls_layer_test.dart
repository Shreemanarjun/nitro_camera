import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/manual_controls_layer.dart';

import 'test_helpers.dart';

void main() {
  setUp(resetStore);

  Future<void> pump(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      harness(
        const Stack(children: [Positioned.fill(child: ManualControlsLayer())]),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('hidden until manualPanelOpen is set', (tester) async {
    await pump(tester);
    expect(find.text('SHUTTER'), findsNothing);
    expect(find.text('AF'), findsNothing);

    cameraStore.manualPanelOpen.value = true;
    await tester.pumpAndSettle();
    expect(find.text('SHUTTER'), findsOneWidget);
    expect(find.text('ISO'), findsOneWidget);
    expect(find.text('AF'), findsOneWidget);
  });

  testWidgets('tapping a shutter stop sets the denominator as nanoseconds',
      (tester) async {
    cameraStore.manualPanelOpen.value = true;
    await pump(tester);

    final chip = find.text('1/125');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();

    // 1/125 s expressed in nanoseconds.
    expect(cameraStore.manualShutterNs.value, closeTo(1e9 / 125, 1));
    // Shutter engaging seeds a sane ISO so manual exposure actually applies.
    expect(cameraStore.manualIso.value, greaterThan(0));
  });

  testWidgets('tapping an ISO stop sets ISO and seeds a shutter',
      (tester) async {
    cameraStore.manualPanelOpen.value = true;
    await pump(tester);

    // '100' is on-screen (leftmost chips); higher stops scroll off the lazy
    // horizontal wheel, so pick a visible one — the wiring is identical.
    final chip = find.text('100');
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(cameraStore.manualIso.value, 100);
    expect(cameraStore.manualShutterNs.value, greaterThan(0));
  });

  testWidgets('AUTO shutter clears both manual exposure values', (tester) async {
    cameraStore.manualPanelOpen.value = true;
    cameraStore.manualIso.value = 400;
    cameraStore.manualShutterNs.value = 1e9 / 250;
    // Engage manual focus so the rail shows a number, not its own 'AUTO'
    // bubble — leaving the SHUTTER wheel's AUTO as the first 'AUTO' in the tree.
    cameraStore.focusDistance.value = 0.5;
    await pump(tester);

    final auto = find.text('AUTO').first;
    await tester.tap(auto);
    await tester.pumpAndSettle();

    expect(cameraStore.manualIso.value, lessThan(0));
    expect(cameraStore.manualShutterNs.value, lessThan(0));
  });

  testWidgets('dragging the focus rail engages manual focus', (tester) async {
    cameraStore.manualPanelOpen.value = true;
    await pump(tester);

    expect(cameraStore.focusDistance.value, lessThan(0)); // AUTO to start
    // Drag on the rail: any vertical drag maps into [0,1] manual focus.
    await tester.drag(find.byIcon(Icons.local_florist_rounded), const Offset(0, -40));
    await tester.pumpAndSettle();

    expect(cameraStore.focusDistance.value, inInclusiveRange(0.0, 1.0));
  });

  testWidgets('AF bubble restores auto focus', (tester) async {
    cameraStore.manualPanelOpen.value = true;
    cameraStore.focusDistance.value = 0.5;
    await pump(tester);

    await tester.tap(find.text('AF'));
    await tester.pumpAndSettle();
    expect(cameraStore.focusDistance.value, lessThan(0));
  });
}
