import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:signals/signals_flutter.dart';

import '../../camera/state/camera_store.dart';
import '../services/capture_storage.dart';
import '../services/media_services.dart';
import 'video_player_page.dart';
import 'widgets/gallery_dialogs.dart';
import 'widgets/media_info_sheet.dart';
import 'widgets/media_tile.dart';

/// Opens the full-screen viewer at [initialIndex] (newest-first gallery order).
void openMediaViewer(BuildContext context, {required int initialIndex}) {
  HapticFeedback.selectionClick();
  Navigator.of(context).push(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => MediaViewerScreen(initialIndex: initialIndex),
      transitionsBuilder: (_, anim, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    ),
  );
}

/// Swipeable full-screen viewer across every gallery item (photos, RAW and
/// videos), with share / rotate / delete / info actions.
class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({super.key, required this.initialIndex});

  final int initialIndex;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  /// View-only rotation per item, in quarter turns.
  final Map<String, int> _turns = {};

  /// Bumped after "save rotation" rewrites a file, to drop stale decodes.
  final Map<String, int> _version = {};

  /// Resolution/duration reported by the active video player (for INFO).
  final Map<String, VideoMeta> _videoMeta = {};

  bool _savingRotation = false;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  int _turnsFor(String path) => _turns[path] ?? 0;

  void _rotate(String path) {
    HapticFeedback.selectionClick();
    setState(() => _turns[path] = (_turnsFor(path) + 1) % 4);
  }

  Future<void> _saveRotation(String path) async {
    final turns = _turnsFor(path);
    if (turns == 0 || _savingRotation) return;
    setState(() => _savingRotation = true);
    try {
      await compute(bakeRotationIntoFile, (path: path, quarterTurns: turns));
      // Drop every cached decode of the old pixels (full-res + grid variants).
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (!mounted) return;
      setState(() {
        _turns[path] = 0;
        _version[path] = (_version[path] ?? 0) + 1;
      });
      HapticFeedback.lightImpact();
      showGallerySnack(context, 'Rotation saved');
    } catch (e) {
      if (mounted) showGallerySnack(context, 'Save failed');
      debugPrint('Save rotation failed: $e');
    } finally {
      if (mounted) setState(() => _savingRotation = false);
    }
  }

  Future<void> _share(String path) {
    HapticFeedback.selectionClick();
    return MediaServices.sharer.shareFiles([path]);
  }

  Future<void> _delete(String path) async {
    final ok = await confirmDelete(context, count: 1);
    if (!ok) return;
    HapticFeedback.mediumImpact();
    await cameraStore.removeMedia(path);
    if (!mounted) return;
    final remaining = cameraStore.capturedMedia.value.length;
    if (remaining == 0) {
      // Nothing left to show.
      Navigator.of(context).pop();
    } else if (_index >= remaining) {
      // Deleted the last page — step the pager back onto a valid index.
      setState(() => _index = remaining - 1);
      if (_page.hasClients) _page.jumpToPage(remaining - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final items = cameraStore.capturedMedia.value.reversed.toList();
      if (items.isEmpty) {
        return const Scaffold(backgroundColor: Colors.black);
      }
      final index = _index.clamp(0, items.length - 1);
      final current = items[index];
      final isRaw = CaptureStorage.isRawPath(current.path);
      final rotated = !current.isVideo && _turnsFor(current.path) != 0;
      final bottomPad = MediaQuery.paddingOf(context).bottom;

      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // ── Pager ───────────────────────────────────────────────────────
            Positioned.fill(
              child: PageView.builder(
                controller: _page,
                itemCount: items.length,
                onPageChanged: (i) {
                  HapticFeedback.selectionClick();
                  setState(() => _index = i);
                },
                itemBuilder: (context, i) {
                  final item = items[i];
                  if (item.isVideo) {
                    return VideoPlayerPage(
                      key: ValueKey('video:${item.path}'),
                      path: item.path,
                      active: i == index,
                      bottomPadding: bottomPad + 92,
                      onMeta: (meta) => _videoMeta[item.path] = meta,
                    );
                  }
                  return _PhotoPage(
                    key: ValueKey(
                      'photo:${item.path}:${_version[item.path] ?? 0}',
                    ),
                    path: item.path,
                    quarterTurns: _turnsFor(item.path),
                  );
                },
              ),
            ),

            // ── Top bar ─────────────────────────────────────────────────────
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.basename(current.path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${index + 1} / ${items.length}',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isRaw)
                        Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: rawBadge(),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Bottom action bar ───────────────────────────────────────────
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ActionButton(
                              icon: Icons.ios_share_rounded,
                              label: 'SHARE',
                              onTap: () => _share(current.path),
                            ),
                            if (!current.isVideo)
                              _ActionButton(
                                icon: Icons.rotate_90_degrees_cw_rounded,
                                label: 'ROTATE',
                                onTap: () => _rotate(current.path),
                              ),
                            // RAW is view-only rotate: no re-encode offered.
                            if (rotated && !isRaw)
                              _ActionButton(
                                icon: Icons.save_alt_rounded,
                                label: 'SAVE',
                                color: Colors.cyanAccent,
                                busy: _savingRotation,
                                onTap: () => _saveRotation(current.path),
                              ),
                            _ActionButton(
                              icon: Icons.delete_outline_rounded,
                              label: 'DELETE',
                              color: Colors.redAccent,
                              onTap: () => _delete(current.path),
                            ),
                            _ActionButton(
                              icon: Icons.info_outline_rounded,
                              label: 'INFO',
                              onTap: () => showMediaInfoSheet(
                                context,
                                current,
                                videoMeta: _videoMeta[current.path],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(icon, color: color, size: 22),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: color.withValues(alpha: 0.9),
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Photo page ────────────────────────────────────────────────────────────────

class _PhotoPage extends StatefulWidget {
  const _PhotoPage({super.key, required this.path, required this.quarterTurns});

  final String path;
  final int quarterTurns;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage>
    with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _zoomCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  Animation<Matrix4>? _zoomAnim;
  TapDownDetails? _doubleTapDetails;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
    _zoomCtrl.addListener(() {
      final anim = _zoomAnim;
      if (anim != null) _tc.value = anim.value;
    });
  }

  @override
  void dispose() {
    _zoomCtrl.dispose();
    _tc.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _animateTo(Matrix4 target) {
    _zoomAnim = Matrix4Tween(
      begin: _tc.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomCtrl, curve: Curves.easeOutCubic));
    _zoomCtrl
      ..reset()
      ..forward();
  }

  void _handleDoubleTap() {
    HapticFeedback.selectionClick();
    if (_zoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    final pos = _doubleTapDetails?.localPosition;
    const scale = 2.5;
    final target = Matrix4.identity();
    if (pos != null) {
      target
        ..translateByDouble(-pos.dx * (scale - 1), -pos.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    } else {
      target.scaleByDouble(scale, scale, 1, 1);
    }
    _animateTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final isRaw = CaptureStorage.isRawPath(widget.path);
    final Widget picture = isRaw
        ? _RawPreview(path: widget.path)
        : Image.file(
            File(widget.path),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _RawPreview(path: widget.path),
          );

    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapDetails = d,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        // At 1x, let the PageView own horizontal drags; once zoomed, pan.
        panEnabled: _zoomed,
        minScale: 1.0,
        maxScale: 6.0,
        clipBehavior: Clip.none,
        child: Center(
          child: Hero(
            tag: 'media:${widget.path}',
            child: RotatedBox(
              quarterTurns: widget.quarterTurns,
              child: picture,
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder for RAW/undecodable stills (Flutter has no DNG codec).
class _RawPreview extends StatelessWidget {
  const _RawPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      height: 380,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF17242B), Color(0xFF0B1013)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.camera_rounded, color: Colors.white24, size: 56),
          const SizedBox(height: 18),
          const Text(
            'RAW · DNG',
            style: TextStyle(
              color: Colors.cyanAccent,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'No in-app preview — use SHARE to export.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Text(
            p.basename(path),
            style: const TextStyle(
              color: Colors.white24,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

// ── Save-rotation worker ─────────────────────────────────────────────────────

/// Rewrites [path] with its pixels rotated by `quarterTurns * 90°`, preserving
/// the original EXIF block (GPS, camera fields) and resetting the orientation
/// tag. Runs in a background isolate via [compute].
Future<void> bakeRotationIntoFile(({String path, int quarterTurns}) job) async {
  final file = File(job.path);
  final bytes = await file.readAsBytes();
  final src = img.decodeImage(bytes);
  if (src == null) {
    throw UnsupportedError('Cannot decode ${job.path} for rotation');
  }
  final rotated = img.copyRotate(src, angle: job.quarterTurns * 90);
  rotated.exif = src.exif; // keep GPS / camera metadata
  rotated.exif.imageIfd['Orientation'] = 1; // pixels are upright now
  final ext = p.extension(job.path).toLowerCase();
  final out = ext == '.png'
      ? img.encodePng(rotated)
      : img.encodeJpg(rotated, quality: 95);
  await file.writeAsBytes(out, flush: true);
}
