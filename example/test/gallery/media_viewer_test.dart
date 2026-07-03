import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/camera/state/camera_store.dart';
import 'package:nitro_camera_example/features/gallery/ui/media_viewer_screen.dart';

import '../ui/test_helpers.dart';
import 'gallery_fakes.dart';

void main() {
  setUp(resetStore);

  group('MediaViewerScreen (photo)', () {
    testWidgets('rotate button cycles the displayed quarter turns',
        (tester) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      cameraStore.capturedMedia.value = [
        sandbox.seedPhoto('IMG_20260703_100000.jpg'),
      ];

      await tester.pumpWidget(harness(const MediaViewerScreen(initialIndex: 0)));
      await tester.pumpAndSettle();

      RotatedBox rotation() => tester.widget(find.byType(RotatedBox));
      expect(rotation().quarterTurns, 0);
      // No pending rotation — nothing to save yet.
      expect(find.text('SAVE'), findsNothing);

      await tester.tap(find.text('ROTATE'));
      await tester.pumpAndSettle();
      expect(rotation().quarterTurns, 1);
      // JPEG rotation can be baked into the file.
      expect(find.text('SAVE'), findsOneWidget);

      await tester.tap(find.text('ROTATE'));
      await tester.pumpAndSettle();
      expect(rotation().quarterTurns, 2);

      await tester.tap(find.text('ROTATE'));
      await tester.pumpAndSettle();
      expect(rotation().quarterTurns, 3);

      // Fourth tap wraps back to the original orientation.
      await tester.tap(find.text('ROTATE'));
      await tester.pumpAndSettle();
      expect(rotation().quarterTurns, 0);
      expect(find.text('SAVE'), findsNothing);
    });

    testWidgets('shows share, delete and info actions with the item counter',
        (tester) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      cameraStore.capturedMedia.value = [
        sandbox.seedPhoto('IMG_20260703_100000.jpg'),
        sandbox.seedPhoto('IMG_20260703_100001.jpg'),
      ];

      await tester.pumpWidget(harness(const MediaViewerScreen(initialIndex: 0)));
      await tester.pumpAndSettle();

      expect(find.text('SHARE'), findsOneWidget);
      expect(find.text('DELETE'), findsOneWidget);
      expect(find.text('INFO'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      // Newest first: index 0 is the latest capture.
      expect(find.text('IMG_20260703_100001.jpg'), findsOneWidget);
    });

    testWidgets('share action routes the current path through the injected '
        'sharer', (tester) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      final photo = sandbox.seedPhoto('IMG_20260703_100000.jpg');
      cameraStore.capturedMedia.value = [photo];

      await tester.pumpWidget(harness(const MediaViewerScreen(initialIndex: 0)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('SHARE'));
      await tester.pumpAndSettle();

      expect(sandbox.sharer.calls, [
        [photo.path],
      ]);
    });
  });

  group('MediaViewerScreen (delete)', () {
    testWidgets('delete confirms, removes the file and the store entry',
        (tester) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      final older = sandbox.seedPhoto('IMG_20260703_100000.jpg');
      final newer = sandbox.seedPhoto('IMG_20260703_100001.jpg');
      cameraStore.capturedMedia.value = [older, newer];
      cameraStore.lastCapturedPath.value = newer.path;

      await tester.pumpWidget(harness(const MediaViewerScreen(initialIndex: 0)));
      await tester.pumpAndSettle();

      // Viewer shows the newest item; delete it.
      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      expect(find.text('DELETE 1 ITEM?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'DELETE'));
      await tester.pumpAndSettle();

      expect(cameraStore.capturedMedia.value, [older]);
      expect(File(newer.path).existsSync(), isFalse);
      expect(cameraStore.lastCapturedPath.value, older.path);
    });
  });

  group('MediaViewerScreen (RAW / DNG)', () {
    testWidgets('DNG is view-only rotate: placeholder shown, no SAVE action',
        (tester) async {
      final sandbox = useGallerySandbox();
      usePhoneSurface(tester);
      cameraStore.capturedMedia.value = [
        sandbox.seedRaw('RAW_20260703_100000.dng'),
      ];

      await tester.pumpWidget(harness(const MediaViewerScreen(initialIndex: 0)));
      await tester.pumpAndSettle();

      expect(find.text('RAW · DNG'), findsOneWidget);
      expect(find.text('RAW'), findsOneWidget); // top-bar badge

      await tester.tap(find.text('ROTATE'));
      await tester.pumpAndSettle();
      final rotation = tester.widget<RotatedBox>(find.byType(RotatedBox));
      expect(rotation.quarterTurns, 1);
      // Re-encoding DNG is unsupported — no save-rotation offer.
      expect(find.text('SAVE'), findsNothing);
    });
  });
}
