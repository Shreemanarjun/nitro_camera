import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';
import '../sheets/settings_sheet.dart';

/// Quick-settings dropdown anchored under the top icon strip (opened by the
/// tune icon or the config caption): segmented rows for RESOLUTION
/// (720P/1080P + 4K when the sensor has a UHD format), FPS (30/60), ASPECT
/// (FULL/16:9/4:3/1:1) and the promoted high-value settings (white-balance
/// presets, HDR, stabilization, geotag, video codec), plus the ALL SETTINGS
/// entry that used to float as a separate pill.
class QuickPanel extends StatelessWidget {
  const QuickPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final open = cameraStore.quickSettingsOpen.value;
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SizeTransition(
            sizeFactor: anim,
            alignment: Alignment.topCenter,
            child: child,
          ),
        ),
        child: open
            ? _panel(context)
            : const SizedBox.shrink(key: ValueKey('qp_closed')),
      );
    });
  }

  Widget _panel(BuildContext context) {
    return Container(
      key: const ValueKey('qp_open'),
      margin: const EdgeInsets.only(top: 10),
      constraints: const BoxConstraints(maxWidth: 360),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            // Cap the panel height so the promoted rows can never overflow a
            // small screen — the panel scrolls instead of jumping the layout.
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // RESOLUTION — options derive from the active device's formats.
                    Watch((context) {
                      final w = cameraStore.width.value;
                      final has4K = cameraStore.supports4K.value;
                      return _PanelRow(
                        label: 'RESOLUTION',
                        segments: [
                          (
                            '720P',
                            w < 1920,
                            () => cameraStore.setResolution(1280, 720),
                          ),
                          (
                            '1080P',
                            w >= 1920 && w < 3840,
                            () => cameraStore.setResolution(1920, 1080),
                          ),
                          if (has4K)
                            (
                              '4K',
                              w >= 3840,
                              () => cameraStore.setResolution(3840, 2160),
                            ),
                        ],
                      );
                    }),

                    // FPS.
                    Watch((context) {
                      final fps = cameraStore.fps.value;
                      return _PanelRow(
                        label: 'FPS',
                        segments: [
                          ('30', fps == 30, () => cameraStore.setFps(30)),
                          ('60', fps == 60, () => cameraStore.setFps(60)),
                        ],
                      );
                    }),

                    // ASPECT ratio of the preview viewport.
                    Watch((context) {
                      final ar = cameraStore.selectedAspectRatio.value;
                      bool near(double v) =>
                          ar != null && (ar - v).abs() < 0.01;
                      return _PanelRow(
                        label: 'ASPECT',
                        segments: [
                          (
                            'FULL',
                            ar == null,
                            () => cameraStore.selectedAspectRatio.value = null,
                          ),
                          (
                            '16:9',
                            near(16 / 9),
                            () =>
                                cameraStore.selectedAspectRatio.value = 16 / 9,
                          ),
                          (
                            '4:3',
                            near(4 / 3),
                            () => cameraStore.selectedAspectRatio.value = 4 / 3,
                          ),
                          (
                            '1:1',
                            near(1.0),
                            () => cameraStore.selectedAspectRatio.value = 1.0,
                          ),
                        ],
                      );
                    }),

                    Divider(
                      color: Colors.white.withValues(alpha: 0.08),
                      height: 12,
                    ),

                    // ── Promoted settings (also available in ALL SETTINGS) ──

                    // WHITE BALANCE presets via kelvin values (0 = auto).
                    Watch((context) {
                      final k = cameraStore.whiteBalanceKelvin.value;
                      bool near(int v) => (k - v).abs() < 200;
                      return _PanelRow(
                        label: 'WHITE BAL',
                        segments: [
                          (
                            'AUTO',
                            k == 0,
                            () => cameraStore.setWhiteBalance(0),
                          ),
                          (
                            'INCAND',
                            near(3000),
                            () => cameraStore.setWhiteBalance(3000),
                          ),
                          (
                            'DAYLIGHT',
                            near(5500),
                            () => cameraStore.setWhiteBalance(5500),
                          ),
                          (
                            'CLOUDY',
                            near(6500),
                            () => cameraStore.setWhiteBalance(6500),
                          ),
                        ],
                      );
                    }),

                    // HDR.
                    Watch((context) {
                      final on = cameraStore.hdrEnabled.value;
                      return _PanelRow(
                        label: 'HDR',
                        segments: [
                          ('OFF', !on, () => cameraStore.setHdr(false)),
                          ('ON', on, () => cameraStore.setHdr(true)),
                        ],
                      );
                    }),

                    // VIDEO STABILIZATION.
                    Watch((context) {
                      final v = cameraStore.videoStabilization.value;
                      return _PanelRow(
                        label: 'STABILIZE',
                        segments: [
                          (
                            'OFF',
                            v == 0,
                            () => cameraStore.setVideoStabilization(0),
                          ),
                          (
                            'STD',
                            v == 1,
                            () => cameraStore.setVideoStabilization(1),
                          ),
                          (
                            'CINE',
                            v == 2,
                            () => cameraStore.setVideoStabilization(2),
                          ),
                        ],
                      );
                    }),

                    // GEOTAG captured media.
                    Watch((context) {
                      final on = cameraStore.geotagEnabled.value;
                      return _PanelRow(
                        label: 'GEOTAG',
                        segments: [
                          (
                            'OFF',
                            !on,
                            () => cameraStore.geotagEnabled.value = false,
                          ),
                          (
                            'ON',
                            on,
                            () => cameraStore.geotagEnabled.value = true,
                          ),
                        ],
                      );
                    }),

                    // VIDEO CODEC.
                    Watch((context) {
                      final codec = cameraStore.videoCodec.value;
                      return _PanelRow(
                        label: 'CODEC',
                        segments: [
                          (
                            'H.264',
                            codec == VideoCodec.h264,
                            () =>
                                cameraStore.videoCodec.value = VideoCodec.h264,
                          ),
                          (
                            'H.265',
                            codec == VideoCodec.hevc,
                            () =>
                                cameraStore.videoCodec.value = VideoCodec.hevc,
                          ),
                        ],
                      );
                    }),

                    const SizedBox(height: 4),
                    Divider(
                      color: Colors.white.withValues(alpha: 0.08),
                      height: 12,
                    ),

                    // ALL SETTINGS — the full PRO/CONFIG sheet, relocated here
                    // from the old floating pill.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        cameraStore.quickSettingsOpen.value = false;
                        SettingsSheet.show(context);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.settings_rounded,
                              color: Colors.cyanAccent,
                              size: 15,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'ALL SETTINGS',
                              style: TextStyle(
                                color: Colors.cyanAccent.withValues(
                                  alpha: 0.95,
                                ),
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One labelled segmented row: (label, selected, onTap) triples rendered as an
/// equal-width pill group.
class _PanelRow extends StatelessWidget {
  final String label;
  final List<(String, bool, VoidCallback)> segments;
  const _PanelRow({required this.label, required this.segments});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Row(
                children: segments.map((seg) {
                  final (text, selected, onTap) = seg;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onTap();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.cyanAccent
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          text,
                          style: TextStyle(
                            color: selected ? Colors.black : Colors.white60,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
