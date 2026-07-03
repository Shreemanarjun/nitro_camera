import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'capture_storage.dart';

/// Service locator for the gallery's platform seams. Widget tests swap in
/// fakes (no native channels), production uses the defaults below.
class MediaServices {
  MediaServices._();

  static CaptureStorage storage = CaptureStorage();
  static VideoThumbnails thumbnails = NativeVideoThumbnails();
  static SystemGallery systemGallery = NativeSystemGallery();
  static MediaSharer sharer = NativeMediaSharer();

  /// Restores production defaults (used between tests).
  static void reset() {
    storage = CaptureStorage();
    thumbnails = NativeVideoThumbnails();
    systemGallery = NativeSystemGallery();
    sharer = NativeMediaSharer();
  }
}

// ── Video thumbnails / metadata ─────────────────────────────────────────────

abstract class VideoThumbnails {
  /// Cached tile thumbnail for [videoPath] (generated once into `.thumbs`).
  Future<File?> tileFor(String videoPath);

  /// Cached clip duration (probed once, persisted as a `.dur` sidecar).
  Future<Duration?> durationOf(String videoPath);

  /// One-off scrub-preview frame at [position] (small JPEG, no caching).
  Future<Uint8List?> frameAt(String videoPath, Duration position);

  /// Drops cached artifacts after a video is deleted.
  Future<void> evict(String videoPath);
}

class NativeVideoThumbnails implements VideoThumbnails {
  final _tileJobs = <String, Future<File?>>{};
  final _durations = <String, Duration>{};

  Future<File> _thumbFile(String videoPath, String ext) async {
    final dir = await MediaServices.storage.thumbsDir();
    final name = p.basenameWithoutExtension(videoPath);
    return File(p.join(dir.path, '$name$ext'));
  }

  @override
  Future<File?> tileFor(String videoPath) =>
      _tileJobs.putIfAbsent(videoPath, () => _generateTile(videoPath));

  Future<File?> _generateTile(String videoPath) async {
    try {
      final out = await _thumbFile(videoPath, '.jpg');
      if (await out.exists()) return out;
      final data = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 512,
        quality: 75,
      );
      await out.writeAsBytes(data, flush: true);
      return out;
    } catch (e) {
      debugPrint('Video thumbnail failed for $videoPath: $e');
      _tileJobs.remove(videoPath); // allow a retry later
      return null;
    }
  }

  @override
  Future<Duration?> durationOf(String videoPath) async {
    final hit = _durations[videoPath];
    if (hit != null) return hit;
    try {
      final sidecar = await _thumbFile(videoPath, '.dur');
      if (await sidecar.exists()) {
        final ms = int.tryParse(await sidecar.readAsString());
        if (ms != null) return _durations[videoPath] = Duration(milliseconds: ms);
      }
      final d = await _probeDuration(videoPath);
      if (d == null) return null;
      await sidecar.writeAsString('${d.inMilliseconds}', flush: true);
      return _durations[videoPath] = d;
    } catch (e) {
      debugPrint('Video duration probe failed for $videoPath: $e');
      return null;
    }
  }

  Future<Duration?> _probeDuration(String videoPath) async {
    final player = Player();
    try {
      await player.open(Media(videoPath), play: false);
      return await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    } finally {
      await player.dispose();
    }
  }

  @override
  Future<Uint8List?> frameAt(String videoPath, Duration position) async {
    try {
      return await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 240,
        timeMs: position.inMilliseconds,
        quality: 60,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> evict(String videoPath) async {
    _tileJobs.remove(videoPath);
    _durations.remove(videoPath);
    for (final ext in const ['.jpg', '.dur']) {
      try {
        await (await _thumbFile(videoPath, ext)).delete();
      } catch (_) {}
    }
  }
}

// ── System gallery (Photos / MediaStore) ────────────────────────────────────

abstract class SystemGallery {
  /// Best-effort mirror of a capture into the OS gallery. Never throws.
  Future<void> trySave(String path, {required bool isVideo});
}

class NativeSystemGallery implements SystemGallery {
  @override
  Future<void> trySave(String path, {required bool isVideo}) async {
    try {
      if (isVideo) {
        await Gal.putVideo(path);
      } else {
        await Gal.putImage(path);
      }
    } catch (e) {
      // Non-fatal: the in-app library still owns the file.
      debugPrint('System gallery save skipped: $e');
    }
  }
}

// ── Share sheet ─────────────────────────────────────────────────────────────

abstract class MediaSharer {
  Future<void> shareFiles(List<String> paths);
}

class NativeMediaSharer implements MediaSharer {
  @override
  Future<void> shareFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    await SharePlus.instance.share(
      ShareParams(files: [for (final path in paths) XFile(path)]),
    );
  }
}
