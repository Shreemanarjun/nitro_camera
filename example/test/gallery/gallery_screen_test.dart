import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/gallery/ui/gallery_screen.dart';
import 'package:nitro_camera_example/features/gallery/ui/widgets/media_tile.dart';

import '../ui/test_helpers.dart';
import 'gallery_fakes.dart';

void main() {
  setUp(resetStore);

  group('GalleryScreen', () {
    testWidgets('shows the empty state when there are no captures', (
      tester,
    ) async {
      useGallerySandbox();
      usePhoneSurface(tester);
      await tester.pumpWidget(harness(const GalleryScreen()));
      await tester.pumpAndSettle();

      expect(find.text('NO CAPTURES YET'), findsOneWidget);
      expect(find.text('0 ITEMS'), findsOneWidget);
      expect(find.byType(MediaTile), findsNothing);
    });

    testWidgets('renders a grid of seeded photos and videos, newest first', (
      tester,
    ) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      cameraStore.capturedMedia.value = [
        sandbox.seedPhoto('IMG_20260703_100000.jpg'),
        sandbox.seedPhoto('IMG_20260703_100001.jpg'),
        sandbox.seedVideo('VID_20260703_100002.mp4'),
      ];

      await tester.pumpWidget(harness(const GalleryScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(MediaTile), findsNWidgets(3));
      expect(find.text('3 ITEMS'), findsOneWidget);
      // Video tile: play glyph + duration badge from the fake provider.
      expect(find.byIcon(Icons.play_circle_outline_rounded), findsOneWidget);
      expect(find.text('00:05'), findsOneWidget);
    });

    testWidgets('video tile shows the duration badge from the injected '
        'thumbnail provider', (tester) async {
      final sandbox = useGallerySandbox();
      sandbox.thumbnails.duration = const Duration(minutes: 1, seconds: 23);
      usePhoneSurface(tester);
      cameraStore.capturedMedia.value = [
        sandbox.seedVideo('VID_20260703_100002.mp4'),
      ];

      await tester.pumpWidget(harness(const GalleryScreen()));
      await tester.pumpAndSettle();

      expect(find.text('01:23'), findsOneWidget);
    });

    testWidgets('DNG tile shows the RAW badge', (tester) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      cameraStore.capturedMedia.value = [
        sandbox.seedRaw('RAW_20260703_100003.dng'),
      ];

      await tester.pumpWidget(harness(const GalleryScreen()));
      await tester.pumpAndSettle();

      expect(find.text('RAW'), findsOneWidget);
    });

    testWidgets('long-press enters multi-select and taps toggle selection', (
      tester,
    ) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      cameraStore.capturedMedia.value = [
        sandbox.seedPhoto('IMG_20260703_100000.jpg'),
        sandbox.seedPhoto('IMG_20260703_100001.jpg'),
      ];

      await tester.pumpWidget(harness(const GalleryScreen()));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaTile).first);
      await tester.pumpAndSettle();
      expect(find.text('1 SELECTED'), findsOneWidget);

      await tester.tap(find.byType(MediaTile).last);
      await tester.pumpAndSettle();
      expect(find.text('2 SELECTED'), findsOneWidget);

      // Tapping an already-selected tile deselects it.
      await tester.tap(find.byType(MediaTile).last);
      await tester.pumpAndSettle();
      expect(find.text('1 SELECTED'), findsOneWidget);

      // Leaving selection mode restores the normal app bar.
      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();
      expect(find.text('GALLERY'), findsOneWidget);
    });

    testWidgets('share in multi-select routes the selected paths through the '
        'injected sharer', (tester) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      final photo = sandbox.seedPhoto('IMG_20260703_100000.jpg');
      cameraStore.capturedMedia.value = [
        photo,
        sandbox.seedPhoto('IMG_20260703_100001.jpg'),
      ];

      await tester.pumpWidget(harness(const GalleryScreen()));
      await tester.pumpAndSettle();

      // Select the oldest photo (last tile in the newest-first grid).
      await tester.longPress(find.byType(MediaTile).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Share'));
      await tester.pumpAndSettle();

      expect(sandbox.sharer.calls, [
        [photo.path],
      ]);
    });
  });
}
