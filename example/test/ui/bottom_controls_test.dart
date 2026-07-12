import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/camera/ui/widgets/controls/bottom_controls.dart';

import 'test_helpers.dart';

void main() {
  setUp(resetStore);

  group('BottomControls', () {
    testWidgets('gallery, shutter and flip controls carry tooltips', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const BottomControls()));

      expect(find.byTooltip('Gallery'), findsOneWidget);
      expect(find.byTooltip('Take photo'), findsOneWidget);
      expect(find.byTooltip('Switch camera'), findsOneWidget);
    });

    testWidgets('shutter tooltip follows the capture mode', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const BottomControls()));

      cameraStore.mode.value = 'VIDEO';
      await tester.pump();
      expect(find.byTooltip('Record video'), findsOneWidget);
      expect(find.byTooltip('Take photo'), findsNothing);

      cameraStore.isRecording.value = true;
      await tester.pump();
      expect(find.byTooltip('Stop recording'), findsOneWidget);

      cameraStore.isRecording.value = false;
      cameraStore.mode.value = 'SCANNER';
      await tester.pump();
      expect(find.byTooltip('Take photo'), findsOneWidget);
    });

    testWidgets('mode swiper renders all three modes and switches on tap', (
      tester,
    ) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const BottomControls()));

      expect(find.text('SCANNER'), findsOneWidget);
      expect(find.text('PHOTO'), findsOneWidget);
      expect(find.text('VIDEO'), findsOneWidget);

      await tester.tap(find.text('VIDEO'));
      await tester.pumpAndSettle();
      expect(cameraStore.mode.value, 'VIDEO');
    });
  });
}
