import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/gallery/services/capture_storage.dart';
import 'package:nitro_camera_example/features/gallery/services/media_services.dart';

/// A valid 1×1 transparent PNG — decodable by Flutter regardless of the
/// file extension it is written under.
final Uint8List kTinyImageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
  'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Injectable stand-in for the native thumbnail/duration plugin: no
/// platform channels, fully deterministic.
class FakeThumbnails implements VideoThumbnails {
  FakeThumbnails({this.tile, this.duration, this.frame});

  File? tile;
  Duration? duration;
  Uint8List? frame;
  int frameRequests = 0;
  final evicted = <String>[];

  @override
  Future<File?> tileFor(String videoPath) async => tile;

  @override
  Future<Duration?> durationOf(String videoPath) async => duration;

  final primed = <String, Duration>{};

  @override
  Future<void> primeDuration(String videoPath, Duration d) async {
    primed[videoPath] = d;
  }

  @override
  Future<Uint8List?> frameAt(String videoPath, Duration position) async {
    frameRequests++;
    return frame;
  }

  @override
  Future<void> evict(String videoPath) async => evicted.add(videoPath);
}

class RecordingSharer implements MediaSharer {
  final calls = <List<String>>[];

  @override
  Future<void> shareFiles(List<String> paths) async => calls.add(paths);
}

class RecordingSystemGallery implements SystemGallery {
  final saved = <String>[];

  @override
  Future<void> trySave(String path, {required bool isVideo}) async =>
      saved.add(path);
}

/// A per-test sandbox: temp dir + fake services wired into [MediaServices].
class GallerySandbox {
  GallerySandbox()
      : dir = Directory.systemTemp.createTempSync('nitro_gallery_test') {
    thumbnails = FakeThumbnails(
      tile: writeFile('thumb.png', kTinyImageBytes),
      duration: const Duration(seconds: 5),
    );
    MediaServices.storage = CaptureStorage(root: dir);
    MediaServices.thumbnails = thumbnails;
    MediaServices.sharer = sharer;
    MediaServices.systemGallery = systemGallery;
  }

  final Directory dir;
  late final FakeThumbnails thumbnails;
  final sharer = RecordingSharer();
  final systemGallery = RecordingSystemGallery();

  File writeFile(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes, flush: true);

  MediaEntry seedPhoto(String name) =>
      (path: writeFile(name, kTinyImageBytes).path, isVideo: false);

  MediaEntry seedVideo(String name) =>
      (path: writeFile(name, [0, 0, 0, 0]).path, isVideo: true);

  MediaEntry seedRaw(String name) =>
      (path: writeFile(name, [0x4D, 0x4D, 0, 42]).path, isVideo: false);

  void dispose() {
    MediaServices.reset();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Creates a sandbox and tears it (plus the service locator) down after the
/// current test.
GallerySandbox useGallerySandbox() {
  final sandbox = GallerySandbox();
  addTearDown(sandbox.dispose);
  return sandbox;
}
