import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/common/upright.dart';
import 'package:signals_flutter/signals_flutter.dart';

void main() {
  double turnsOf(WidgetTester tester) =>
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns;

  testWidgets('starts at the current rotation and always turns the short way', (
    tester,
  ) async {
    final rotation = signal(-90);
    await tester.pumpWidget(
      MaterialApp(
        home: Upright(rotation: rotation, child: const Icon(Icons.flash_off)),
      ),
    );
    expect(turnsOf(tester), -0.25);

    // -90 → 180: a quarter turn further back, not three quarters forward.
    rotation.value = 180;
    await tester.pump();
    expect(turnsOf(tester), -0.5);

    // 180 → 90: the short way is another quarter back (-270° looks like 90°).
    rotation.value = 90;
    await tester.pump();
    expect(turnsOf(tester), -0.75);

    // 90 → 0 → -90: keeps stepping a quarter at a time, never jumping.
    rotation.value = 0;
    await tester.pump();
    expect(turnsOf(tester), -1.0);
    rotation.value = -90;
    await tester.pump();
    expect(turnsOf(tester), -1.25);

    // -90 → 0: a quarter forward, back to upright.
    rotation.value = 0;
    await tester.pump();
    expect(turnsOf(tester), -1.0);
  });

  testWidgets('an unchanged rotation leaves the turns alone across rebuilds', (
    tester,
  ) async {
    final rotation = signal(90);
    await tester.pumpWidget(
      MaterialApp(
        home: Upright(
          rotation: rotation,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Upright(
          rotation: rotation,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    expect(turnsOf(tester), 0.25);
  });
}
