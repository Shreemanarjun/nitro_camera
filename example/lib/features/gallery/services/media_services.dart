import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
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

  /// Seeds the duration cache for a freshly-recorded clip whose length is
  /// already known (from the recorder's result) — so [durationOf] never has
  /// to probe the file at all.
  Future<void> primeDuration(String videoPath, Duration duration);

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

  @override
  Future<void> primeDuration(String videoPath, Duration duration) async {
    if (duration <= Duration.zero) return;
    _durations[videoPath] = duration;
    try {
      final sidecar = await _thumbFile(videoPath, '.dur');
      await sidecar.writeAsString('${duration.inMilliseconds}', flush: true);
    } catch (e) {
      debugPrint('Duration sidecar write failed for $videoPath: $e');
    }
  }

  // Pure-Dart MP4/MOV duration read (moov→mvhd box). Spinning up a media_kit
  // Player for a metadata probe crashes on iOS 26 (see
  // docs/PERF_MEMORY_ASYNC_PLAN.md, item 0) — and every capture path also
  // primes the sidecar, so this only runs for pre-existing files.
  Future<Duration?> _probeDuration(String videoPath) => probeMp4Duration(videoPath);

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

// ── Pure-Dart MP4/MOV duration probe ────────────────────────────────────────
//
// Walks the ISO-BMFF box tree with seeks (no full read — moov-at-end files
// stay cheap) to moov→mvhd and computes duration/timescale. Handles 32- and
// 64-bit box sizes and mvhd versions 0/1. Returns null for anything it does
// not understand.

/// Reads an MP4/MOV file's duration from its container header.
Future<Duration?> probeMp4Duration(String path) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    return await _scanBoxes(f, 0, await f.length(), inMoov: false);
  } catch (_) {
    return null;
  } finally {
    await f?.close();
  }
}

Future<Duration?> _scanBoxes(
  RandomAccessFile f,
  int start,
  int end, {
  required bool inMoov,
}) async {
  var offset = start;
  while (offset + 8 <= end) {
    await f.setPosition(offset);
    final header = await f.read(16);
    if (header.length < 8) return null;
    var size = _be32(header, 0);
    final type = String.fromCharCodes(header.sublist(4, 8));
    var headerLen = 8;
    if (size == 1) {
      // 64-bit "largesize" box.
      if (header.length < 16) return null;
      size = _be64(header, 8);
      headerLen = 16;
    } else if (size == 0) {
      size = end - offset; // box extends to the end of the enclosing scope
    }
    if (size < headerLen) return null; // corrupt — would loop forever
    if (!inMoov && type == 'moov') {
      final d =
          await _scanBoxes(f, offset + headerLen, offset + size, inMoov: true);
      if (d != null) return d;
    } else if (inMoov && type == 'mvhd') {
      return _parseMvhd(f, offset + headerLen, offset + size);
    }
    offset += size;
  }
  return null;
}

Future<Duration?> _parseMvhd(RandomAccessFile f, int start, int end) async {
  await f.setPosition(start);
  final len = end - start;
  final b = await f.read(len < 32 ? len : 32);
  if (b.isEmpty) return null;
  final version = b[0];
  final int timescale;
  final int duration;
  if (version == 1) {
    // version+flags(4) creation(8) modification(8) timescale(4) duration(8)
    if (b.length < 32) return null;
    timescale = _be32(b, 20);
    duration = _be64(b, 24);
  } else {
    // version+flags(4) creation(4) modification(4) timescale(4) duration(4)
    if (b.length < 20) return null;
    timescale = _be32(b, 12);
    duration = _be32(b, 16);
    if (duration == 0xFFFFFFFF) return null; // "unknown" sentinel
  }
  if (timescale <= 0 || duration <= 0) return null;
  return Duration(microseconds: (duration * 1000000) ~/ timescale);
}

int _be32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _be64(List<int> b, int o) => (_be32(b, o) << 32) | _be32(b, o + 4);

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
