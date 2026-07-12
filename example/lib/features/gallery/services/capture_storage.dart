import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A gallery entry: an absolute file path + whether it is a video.
typedef MediaEntry = ({String path, bool isVideo});

/// Permanent on-device library for captures.
///
/// Layout (under the app documents dir — survives cache eviction):
/// ```
/// <documents>/captures/
///   IMG_20260703_154210.jpg      // JPEG photo
///   RAW_20260703_154211.dng      // RAW photo
///   VID_20260703_154530.mp4      // video (mp4/mov)
///   .thumbs/                     // cached video thumbnails + sidecars
/// ```
///
/// Files are *moved* (rename, or byte-copy across filesystems) so the bytes —
/// including natively-written EXIF/GPS metadata — are preserved untouched.
class CaptureStorage {
  /// [root] overrides the documents dir (used by tests to avoid path_provider).
  CaptureStorage({Directory? root}) : _root = root;

  final Directory? _root;
  Directory? _dir;

  static const videoExtensions = {'.mp4', '.mov', '.m4v'};
  static const imageExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.dng'};

  static bool isVideoPath(String path) =>
      videoExtensions.contains(p.extension(path).toLowerCase());

  static bool isRawPath(String path) =>
      p.extension(path).toLowerCase() == '.dng';

  Future<Directory> capturesDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = _root ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'captures'));
    await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Hidden cache for video tile thumbnails / duration sidecars.
  Future<Directory> thumbsDir() async {
    final dir = Directory(p.join((await capturesDir()).path, '.thumbs'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Moves a fresh capture out of the cache dir into the library with a clean
  /// `IMG_/RAW_/VID_<timestamp>` name. Returns the new absolute path.
  Future<String> persist(String srcPath, {DateTime? capturedAt}) async {
    final src = File(srcPath);
    final dir = await capturesDir();
    final ext = p.extension(srcPath).toLowerCase();
    final prefix = videoExtensions.contains(ext)
        ? 'VID'
        : (ext == '.dng' ? 'RAW' : 'IMG');
    final stamp = _stamp(capturedAt ?? _bestCaptureTime(src));

    var target = File(p.join(dir.path, '${prefix}_$stamp$ext'));
    var n = 1;
    while (await target.exists()) {
      target = File(p.join(dir.path, '${prefix}_${stamp}_${n++}$ext'));
    }
    try {
      await src.rename(target.path); // byte-preserving move
    } on FileSystemException {
      // Cross-filesystem move: byte-copy, then best-effort cleanup.
      await src.copy(target.path);
      try {
        await src.delete();
      } catch (_) {}
    }
    return target.path;
  }

  /// Scans the library, newest first (timestamps are embedded in the names).
  Future<List<MediaEntry>> loadAll() async {
    final dir = await capturesDir();
    final entries = <MediaEntry>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final ext = p.extension(e.path).toLowerCase();
      if (videoExtensions.contains(ext)) {
        entries.add((path: e.path, isVideo: true));
      } else if (imageExtensions.contains(ext)) {
        entries.add((path: e.path, isVideo: false));
      }
    }
    entries.sort((a, b) {
      final byTime = _sortKey(b.path).compareTo(_sortKey(a.path));
      return byTime != 0
          ? byTime
          : p.basename(b.path).compareTo(p.basename(a.path));
    });
    return entries;
  }

  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  DateTime _bestCaptureTime(File f) {
    try {
      return f.lastModifiedSync();
    } catch (_) {
      return DateTime.now();
    }
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Timestamp portion of the filename (drops the IMG_/RAW_/VID_ prefix so
  /// mixed media still sorts chronologically).
  static String _sortKey(String path) {
    final name = p.basenameWithoutExtension(path);
    return RegExp(r'^(IMG|RAW|VID)_').hasMatch(name) ? name.substring(4) : name;
  }
}
