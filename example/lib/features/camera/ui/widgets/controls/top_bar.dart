import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';
import 'quick_panel.dart';

/// Top control strip — a single compact, non-scrolling row of icon toggles
/// (stock-camera style): flash · filters · preview path · RAW · face detect ·
/// quick settings. Below it, a tiny "1080P · 60" caption reflects the active
/// stream config; tapping either the tune icon or the caption drops down the
/// [QuickPanel] with the resolution / fps / aspect segments and the SETTINGS
/// entry point.
class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _iconStrip(),
            const SizedBox(height: 6),
            _configCaption(),
            const QuickPanel(),
          ],
        ),
      ),
    );
  }

  /// The frosted-glass icon strip. Every target is 40×40.
  Widget _iconStrip() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.40),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // FLASH — off → on → auto (always reachable; the native setter
              // is capability-guarded on devices without a flash unit).
              Watch((context) {
                final flash = cameraStore.flashMode.value;
                final (icon, color) = switch (flash) {
                  FlashMode.off => (Icons.flash_off_rounded, Colors.white70),
                  FlashMode.on => (Icons.flash_on_rounded, Colors.amberAccent),
                  FlashMode.auto =>
                    (Icons.flash_auto_rounded, Colors.cyanAccent),
                };
                return _StripIcon(
                  icon: icon,
                  color: color,
                  active: flash != FlashMode.off,
                  activeColor: color,
                  onTap: () {
                    final modes = FlashMode.values;
                    cameraStore
                        .setFlash(modes[(flash.index + 1) % modes.length]);
                  },
                );
              }),

              // FILTERS tray toggle.
              Watch((context) {
                final show = cameraStore.showFilters.value;
                return _StripIcon(
                  icon: Icons.auto_awesome,
                  active: show,
                  onTap: () => cameraStore.showFilters.value = !show,
                );
              }),

              // PREVIEW PATH — Texture ↔ platform view (active = PV).
              Watch((context) {
                final mode = cameraStore.previewMode.value;
                final isPv = mode == PreviewMode.platformView;
                return _StripIcon(
                  icon: Icons.layers_rounded,
                  active: isPv,
                  onTap: () => cameraStore.setPreviewMode(
                    isPv ? PreviewMode.texture : PreviewMode.platformView,
                  ),
                );
              }),

              // RAW (DNG) — mini text badge, only when the sensor supports it.
              Watch((context) {
                final dev = cameraStore.currentDevice.value;
                if (dev == null || !dev.supportsRawCapture) {
                  return const SizedBox.shrink();
                }
                final raw = cameraStore.rawPhoto.value;
                return _StripBadge(
                  label: 'RAW',
                  active: raw,
                  onTap: () => cameraStore.rawPhoto.value = !raw,
                );
              }),

              // NATIVE ML KIT FACE DETECTION.
              Watch((context) {
                final det = cameraStore.nativeDetector.value;
                final on = det == 'face';
                return _StripIcon(
                  icon: Icons.face_retouching_natural,
                  active: on,
                  onTap: () =>
                      cameraStore.setNativeDetectorMode(on ? '' : 'face'),
                );
              }),

              // Hairline divider before the quick-settings entry.
              Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                color: Colors.white.withValues(alpha: 0.12),
              ),

              // QUICK SETTINGS dropdown (resolution / fps / aspect / settings).
              Watch((context) {
                final open = cameraStore.quickSettingsOpen.value;
                return _StripIcon(
                  icon: Icons.tune_rounded,
                  active: open,
                  onTap: () => cameraStore.quickSettingsOpen.value = !open,
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// "1080P · 60" caption under the strip — tap opens the quick panel.
  Widget _configCaption() {
    return Watch((context) {
      final res = cameraStore.resolutionLabel.value;
      final fps = cameraStore.fps.value;
      final open = cameraStore.quickSettingsOpen.value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => cameraStore.quickSettingsOpen.value = !open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$res · $fps',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(width: 2),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 13,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// One 40×40 icon target in the strip; active state glows cyan (or a custom
/// accent, e.g. amber for flash-on).
class _StripIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final Color? color;
  final Color? activeColor;
  const _StripIcon({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.color,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final accent = activeColor ?? Colors.cyanAccent;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? accent.withValues(alpha: 0.16)
              : Colors.transparent,
        ),
        child: Icon(
          icon,
          size: 20,
          color: active ? accent : (color ?? Colors.white70),
        ),
      ),
    );
  }
}

/// Tiny text badge (RAW) with the same 40×40 hit target as [_StripIcon].
class _StripBadge extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _StripBadge({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: active
                  ? Colors.cyanAccent.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: active
                    ? Colors.cyanAccent
                    : Colors.white.withValues(alpha: 0.45),
                width: 1,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: active ? Colors.cyanAccent : Colors.white70,
                fontSize: 8,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
