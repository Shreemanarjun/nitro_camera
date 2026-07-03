import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/gallery/services/capture_storage.dart';

void main() {
  late Directory root;
  late CaptureStorage storage;

  setUp(() {
    root = Directory.systemTemp.createTempSync('capture_storage_test');
    storage = CaptureStorage(root: root);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  File cacheFile(String name, List<int> bytes) =>
      File('${root.path}/$name')..writeAsBytesSync(bytes, flush: true);

  group('CaptureStorage.persist', () {
    test('moves a JPEG into captures/ as IMG_<timestamp>.jpg, bytes intact',
        () async {
      final src = cacheFile('cap_123.jpg', [1, 2, 3, 4]);
      final when = DateTime(2026, 7, 3, 15, 42, 10);

      final stored = await storage.persist(src.path, capturedAt: when);

      expect(stored, endsWith('captures/IMG_20260703_154210.jpg'));
      expect(File(stored).readAsBytesSync(), [1, 2, 3, 4]);
      expect(src.existsSync(), isFalse, reason: 'source must be moved');
    });

    test('names DNG captures RAW_ and videos VID_', () async {
      final when = DateTime(2026, 7, 3, 8, 5, 9);
      final dng =
          await storage.persist(cacheFile('cap_1.dng', [1]).path, capturedAt: when);
      final mp4 =
          await storage.persist(cacheFile('video_1.mp4', [2]).path, capturedAt: when);

      expect(dng, endsWith('RAW_20260703_080509.dng'));
      expect(mp4, endsWith('VID_20260703_080509.mp4'));
    });

    test('same-second captures get a collision suffix', () async {
      final when = DateTime(2026, 7, 3, 15, 42, 10);
      final a =
          await storage.persist(cacheFile('a.jpg', [1]).path, capturedAt: when);
      final b =
          await storage.persist(cacheFile('b.jpg', [2]).path, capturedAt: when);

      expect(a, endsWith('IMG_20260703_154210.jpg'));
      expect(b, endsWith('IMG_20260703_154210_1.jpg'));
      expect(File(b).readAsBytesSync(), [2]);
    });
  });

  group('CaptureStorage.loadAll', () {
    test('returns library entries newest first across media prefixes',
        () async {
      await storage.persist(cacheFile('a.jpg', [1]).path,
          capturedAt: DateTime(2026, 7, 1, 10, 0, 0));
      await storage.persist(cacheFile('b.mp4', [2]).path,
          capturedAt: DateTime(2026, 7, 2, 10, 0, 0));
      await storage.persist(cacheFile('c.dng', [3]).path,
          capturedAt: DateTime(2026, 7, 3, 10, 0, 0));

      final items = await storage.loadAll();

      expect(items.map((m) => m.path.split('/').last).toList(), [
        'RAW_20260703_100000.dng',
        'VID_20260702_100000.mp4',
        'IMG_20260701_100000.jpg',
      ]);
      expect(items.map((m) => m.isVideo).toList(), [false, true, false]);
    });

    test('ignores the .thumbs cache dir and unknown files', () async {
      await storage.persist(cacheFile('a.jpg', [1]).path,
          capturedAt: DateTime(2026, 7, 1, 10, 0, 0));
      final thumbs = await storage.thumbsDir();
      File('${thumbs.path}/VID_x.jpg').writeAsBytesSync([9]);
      File('${(await storage.capturesDir()).path}/notes.txt')
          .writeAsStringSync('hi');

      final items = await storage.loadAll();

      expect(items, hasLength(1));
      expect(items.single.path, endsWith('IMG_20260701_100000.jpg'));
    });
  });

  test('delete removes the stored file', () async {
    final stored = await storage.persist(cacheFile('a.jpg', [1]).path,
        capturedAt: DateTime(2026, 7, 1, 10, 0, 0));
    expect(File(stored).existsSync(), isTrue);

    await storage.delete(stored);

    expect(File(stored).existsSync(), isFalse);
  });
}
