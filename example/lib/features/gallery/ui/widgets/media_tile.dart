import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/capture_storage.dart';
import '../../services/media_services.dart';

/// mm:ss (h:mm:ss over an hour) badge text for clip durations.
String formatClipDuration(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// One square cell of the gallery grid: photo thumb, video thumb with a
/// duration badge + play glyph, or a RAW (DNG) card. Hero-tagged for the
/// flight into the viewer, with a multi-select overlay.
class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.item,
    required this.onTap,
    required this.onLongPress,
    this.selecting = false,
    this.selected = false,
  });

  final MediaEntry item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (item.isVideo) {
      content = _VideoTileContent(path: item.path);
    } else if (CaptureStorage.isRawPath(item.path)) {
      content = const _RawTileContent();
    } else {
      content = Image.file(
        File(item.path),
        fit: BoxFit.cover,
        cacheWidth: 384,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const _BrokenTileContent(),
      );
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Hero(tag: 'media:${item.path}', child: content),
          // Selection scrim + check mark.
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: selecting ? 1 : 0,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: selected ? 0.35 : 0.15),
                  border: selected
                      ? Border.all(color: Colors.cyanAccent, width: 2)
                      : null,
                ),
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: selected ? Colors.cyanAccent : Colors.white54,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoTileContent extends StatefulWidget {
  const _VideoTileContent({required this.path});
  final String path;

  @override
  State<_VideoTileContent> createState() => _VideoTileContentState();
}

class _VideoTileContentState extends State<_VideoTileContent> {
  late final Future<File?> _thumb = MediaServices.thumbnails.tileFor(widget.path);
  late final Future<Duration?> _duration =
      MediaServices.thumbnails.durationOf(widget.path);

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<File?>(
          future: _thumb,
          builder: (context, snap) {
            final file = snap.data;
            if (file == null) {
              return Container(
                color: Colors.white10,
                child: const Icon(Icons.videocam_rounded,
                    color: Colors.white24, size: 26),
              );
            }
            return Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: 384,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const _BrokenTileContent(),
            );
          },
        ),
        // Legibility scrim behind the badges.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.center,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black45],
            ),
          ),
        ),
        const Center(
          child: Icon(Icons.play_circle_outline_rounded,
              color: Colors.white70, size: 30),
        ),
        Positioned(
          right: 4,
          bottom: 4,
          child: FutureBuilder<Duration?>(
            future: _duration,
            builder: (context, snap) {
              final d = snap.data;
              if (d == null) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  formatClipDuration(d),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RawTileContent extends StatelessWidget {
  const _RawTileContent();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF17242B), Color(0xFF0B1013)],
        ),
      ),
      child: Stack(
        children: [
          const Center(
            child: Icon(Icons.camera_rounded, color: Colors.white24, size: 30),
          ),
          Positioned(left: 4, top: 4, child: rawBadge()),
        ],
      ),
    );
  }
}

/// Shared "RAW" pill used on DNG tiles and in the viewer.
Widget rawBadge() {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: Colors.cyanAccent, width: 0.8),
    ),
    child: const Text(
      'RAW',
      style: TextStyle(
        color: Colors.cyanAccent,
        fontSize: 9,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.2,
      ),
    ),
  );
}

class _BrokenTileContent extends StatelessWidget {
  const _BrokenTileContent();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white10,
      child: const Icon(Icons.broken_image_outlined,
          color: Colors.white24, size: 24),
    );
  }
}
