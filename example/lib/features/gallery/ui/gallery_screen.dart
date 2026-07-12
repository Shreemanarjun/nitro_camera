import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';

import '../../camera/state/camera_store.dart';
import '../services/capture_storage.dart';
import '../services/media_services.dart';
import 'media_viewer_screen.dart';
import 'widgets/gallery_dialogs.dart';
import 'widgets/media_tile.dart';

/// Pushes the gallery with the app's standard 260ms fade/slide transition.
void openGallery(BuildContext context) {
  HapticFeedback.selectionClick();
  Navigator.of(context).push(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => const GalleryScreen(),
      transitionsBuilder: (_, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

/// Full-screen media library: 3-column grid (newest first), multi-select with
/// share/delete, and hero flights into [MediaViewerScreen].
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  bool _selecting = false;
  final Set<String> _selected = {};

  void _exitSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _toggle(String path) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  Future<void> _shareSelected(List<MediaEntry> items) async {
    if (_selected.isEmpty) return;
    HapticFeedback.selectionClick();
    // Keep grid (newest-first) order in the share sheet.
    final paths = [
      for (final m in items)
        if (_selected.contains(m.path)) m.path,
    ];
    await MediaServices.sharer.shareFiles(paths);
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final ok = await confirmDelete(context, count: _selected.length);
    if (!ok) return;
    HapticFeedback.mediumImpact();
    for (final path in _selected.toList()) {
      await cameraStore.removeMedia(path);
    }
    if (mounted) _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final items = cameraStore.capturedMedia.value.reversed.toList();

      return Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: _buildAppBar(items),
        body: items.isEmpty ? const _EmptyState() : _buildGrid(items),
      );
    });
  }

  PreferredSizeWidget _buildAppBar(List<MediaEntry> items) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(color: Colors.black.withValues(alpha: 0.4)),
        ),
      ),
      leading: IconButton(
        tooltip: _selecting ? 'Cancel selection' : 'Close',
        icon: Icon(
          _selecting ? Icons.close_rounded : Icons.arrow_back_ios_new_rounded,
          color: Colors.white,
          size: 20,
        ),
        onPressed: () {
          if (_selecting) {
            _exitSelection();
          } else {
            Navigator.pop(context);
          }
        },
      ),
      title: _selecting
          ? Text(
              '${_selected.length} SELECTED',
              style: const TextStyle(
                color: Colors.cyanAccent,
                fontSize: 13,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'GALLERY',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  '${items.length} ITEM${items.length == 1 ? '' : 'S'}',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
      actions: [
        if (_selecting) ...[
          IconButton(
            tooltip: 'Share',
            icon: const Icon(
              Icons.ios_share_rounded,
              color: Colors.white,
              size: 20,
            ),
            onPressed: () => _shareSelected(items),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: Colors.redAccent,
              size: 22,
            ),
            onPressed: _deleteSelected,
          ),
        ] else if (items.isNotEmpty)
          IconButton(
            tooltip: 'Select',
            icon: const Icon(
              Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
            onPressed: () {
              HapticFeedback.selectionClick();
              setState(() => _selecting = true);
            },
          ),
      ],
    );
  }

  Widget _buildGrid(List<MediaEntry> items) {
    final pad = MediaQuery.paddingOf(context);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        2,
        pad.top + kToolbarHeight + 2,
        2,
        pad.bottom + 2,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return MediaTile(
          key: ValueKey('tile:${item.path}'),
          item: item,
          selecting: _selecting,
          selected: _selected.contains(item.path),
          onTap: () {
            if (_selecting) {
              _toggle(item.path);
            } else {
              openMediaViewer(context, initialIndex: i);
            }
          },
          onLongPress: () {
            if (_selecting) return;
            HapticFeedback.mediumImpact();
            setState(() {
              _selecting = true;
              _selected.add(item.path);
            });
          },
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, color: Colors.white12, size: 64),
          SizedBox(height: 18),
          Text(
            'NO CAPTURES YET',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Photos and videos you capture will appear here.',
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
