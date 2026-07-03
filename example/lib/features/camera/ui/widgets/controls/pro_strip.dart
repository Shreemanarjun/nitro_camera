import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';
import '../common/glass_tooltip.dart';

/// Mode-aware PRO strip: a slim horizontally-scrollable pill row that sits
/// directly above the mode tabs and puts the high-value pro settings one tap
/// away, contextual per mode:
///
///  * PHOTO   — QUALITY (speed/balanced/quality cycle), HDR, LOW LIGHT,
///              EV (slider bubble), WB (preset cycle), TORCH (tap toggles,
///              long-press opens the level slider);
///  * SCANNER — FPS (30/60 cycle), ANALYZE 1:N (sampling-rate cycle);
///  * VIDEO   — STABILIZE (off/std/cine cycle), GEOTAG, FPS GRAPH, HDR, TORCH.
///
/// Sliders (EV, torch level) open in a small glass bubble above the strip and
/// auto-dismiss 2.5 s after the last interaction. The strip is hidden by
/// [TrayLayer] while the filter tray is open so the two never overlap.
class ProStrip extends StatefulWidget {
  const ProStrip({super.key});

  /// Pill height (also the strip row height).
  static const double kPillHeight = 32;

  @override
  State<ProStrip> createState() => _ProStripState();
}

/// Which slider bubble is currently open above the strip.
enum _Bubble { none, exposure, torch }

class _ProStripState extends State<ProStrip> {
  _Bubble _bubble = _Bubble.none;
  Timer? _dismissTimer;

  // Close any open bubble on a mode switch — its owning pill may not exist in
  // the new pill set. NOTE: signals' subscribe fires eagerly on attach, so the
  // callback guards with a change check.
  String _lastMode = cameraStore.mode.value;
  void Function()? _modeUnsub;

  @override
  void initState() {
    super.initState();
    _modeUnsub = cameraStore.mode.subscribe((m) {
      if (m == _lastMode) return;
      _lastMode = m;
      _closeBubble();
    });
  }

  @override
  void dispose() {
    _modeUnsub?.call();
    _dismissTimer?.cancel();
    super.dispose();
  }

  /// (Re)arms the 2.5 s auto-dismiss — called on open and on every slider
  /// interaction, so the bubble stays up while the user is dragging.
  void _armDismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _bubble = _Bubble.none);
    });
  }

  void _toggleBubble(_Bubble which) {
    setState(() => _bubble = _bubble == which ? _Bubble.none : which);
    if (_bubble == _Bubble.none) {
      _dismissTimer?.cancel();
    } else {
      _armDismiss();
    }
  }

  void _closeBubble() {
    _dismissTimer?.cancel();
    if (mounted && _bubble != _Bubble.none) {
      setState(() => _bubble = _Bubble.none);
    }
  }

  // ── Cycles ──────────────────────────────────────────────────────────────

  void _cycleQuality() {
    final values = QualityPrioritization.values;
    final next =
        values[(cameraStore.photoQuality.value.index + 1) % values.length];
    cameraStore.photoQuality.value = next;
  }

  void _cycleWhiteBalance() {
    // AUTO → 3000K → 5500K → 6500K → AUTO.
    const presets = [0, 3000, 5500, 6500];
    final k = cameraStore.whiteBalanceKelvin.value;
    var i = presets.indexWhere((p) => (k - p).abs() < 200);
    if (i < 0) i = 0;
    cameraStore.setWhiteBalance(presets[(i + 1) % presets.length]);
  }

  void _cycleStabilization() {
    cameraStore
        .setVideoStabilization((cameraStore.videoStabilization.value + 1) % 3);
  }

  void _cycleFps() {
    cameraStore.setFps(cameraStore.fps.value == 30 ? 60 : 30);
  }

  void _cycleSampling() {
    // Analyze every 1st → 2nd → 3rd frame, then back to every frame.
    final next = cameraStore.samplingRate.value % 3 + 1;
    cameraStore.setSamplingRate(next);
  }

  // ── Labels ──────────────────────────────────────────────────────────────

  static String _qualityLabel(QualityPrioritization q) => switch (q) {
        QualityPrioritization.speed => 'SPEED',
        QualityPrioritization.balanced => 'BALANCED',
        QualityPrioritization.quality => 'QUALITY',
      };

  static String _evLabel(double ev) {
    if (ev == 0) return 'EV 0';
    return 'EV ${ev > 0 ? '+' : ''}${ev.toStringAsFixed(1)}';
  }

  static String _wbLabel(int kelvin) =>
      kelvin == 0 ? 'WB AUTO' : 'WB ${kelvin}K';

  static String _stabLabel(int mode) => switch (mode) {
        1 => 'STAB STD',
        2 => 'STAB CINE',
        _ => 'STAB OFF',
      };

  static String _torchLabel(bool on, double level) {
    if (!on) return 'TORCH';
    if (level >= 0.995) return 'TORCH ON';
    return 'TORCH ${(level * 100).round()}%';
  }

  // ── Pill sets per mode ──────────────────────────────────────────────────

  List<Widget> _photoPills() => [
        Watch((context) {
          final q = cameraStore.photoQuality.value;
          return _ProPill(
            icon: Icons.high_quality_rounded,
            label: _qualityLabel(q),
            tooltip: 'Photo quality',
            active: q != QualityPrioritization.balanced,
            onTap: _cycleQuality,
          );
        }),
        _hdrPill(),
        Watch((context) {
          final on = cameraStore.lowLightBoost.value;
          return _ProPill(
            icon: Icons.nightlight_round,
            label: 'LOW LIGHT',
            tooltip: 'Low light boost',
            active: on,
            onTap: () => cameraStore.setLowLightBoost(!on),
          );
        }),
        _evPill(),
        Watch((context) {
          final k = cameraStore.whiteBalanceKelvin.value;
          return _ProPill(
            icon: Icons.wb_sunny_outlined,
            label: _wbLabel(k),
            tooltip: 'White balance',
            active: k != 0,
            onTap: _cycleWhiteBalance,
          );
        }),
        _torchPill(),
      ];

  List<Widget> _scannerPills() => [
        Watch((context) {
          final fps = cameraStore.fps.value;
          return _ProPill(
            icon: Icons.speed_rounded,
            label: 'FPS $fps',
            tooltip: 'Scan frame rate',
            active: fps != 60,
            onTap: _cycleFps,
          );
        }),
        Watch((context) {
          final rate = cameraStore.samplingRate.value;
          return _ProPill(
            icon: Icons.blur_linear_rounded,
            label: 'ANALYZE 1:$rate',
            tooltip: rate == 1
                ? 'Analyze every frame'
                : 'Analyze every ${rate == 2 ? '2nd' : '${rate}rd'} frame',
            active: rate != 1,
            onTap: _cycleSampling,
          );
        }),
      ];

  List<Widget> _videoPills() => [
        Watch((context) {
          final v = cameraStore.videoStabilization.value;
          return _ProPill(
            icon: Icons.video_stable_rounded,
            label: _stabLabel(v),
            tooltip: 'Video stabilization',
            active: v != 0,
            onTap: _cycleStabilization,
          );
        }),
        Watch((context) {
          final on = cameraStore.geotagEnabled.value;
          return _ProPill(
            icon: Icons.location_on_outlined,
            label: 'GEOTAG',
            tooltip: 'Geotag captures',
            active: on,
            onTap: () => cameraStore.geotagEnabled.value = !on,
          );
        }),
        Watch((context) {
          final on = cameraStore.showFpsGraph.value;
          return _ProPill(
            icon: Icons.show_chart_rounded,
            label: 'FPS GRAPH',
            tooltip: 'FPS graph overlay',
            active: on,
            onTap: () => cameraStore.showFpsGraph.value = !on,
          );
        }),
        _hdrPill(),
        _torchPill(),
      ];

  // Shared pills (PHOTO + VIDEO).

  Widget _hdrPill() => Watch((context) {
        final on = cameraStore.hdrEnabled.value;
        return _ProPill(
          icon: Icons.hdr_on_rounded,
          label: 'HDR',
          tooltip: 'HDR',
          active: on,
          onTap: () => cameraStore.setHdr(!on),
        );
      });

  Widget _evPill() => Watch((context) {
        final ev = cameraStore.exposure.value;
        return _ProPill(
          icon: Icons.exposure_rounded,
          label: _evLabel(ev),
          tooltip: 'Exposure compensation',
          active: ev != 0 || _bubble == _Bubble.exposure,
          onTap: () => _toggleBubble(_Bubble.exposure),
        );
      });

  Widget _torchPill() => Watch((context) {
        final on = cameraStore.torch.value;
        final level = cameraStore.torchLevel.value;
        return _ProPill(
          icon: on
              ? Icons.flashlight_on_rounded
              : Icons.flashlight_off_rounded,
          label: _torchLabel(on, level),
          tooltip: 'Torch — long-press for level',
          active: on,
          onTap: () => cameraStore.setTorch(!on),
          onLongPress: () {
            HapticFeedback.mediumImpact();
            _toggleBubble(_Bubble.torch);
          },
        );
      });

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final mode = cameraStore.mode.value;
      final pills = switch (mode) {
        'VIDEO' => _videoPills(),
        'SCANNER' => _scannerPills(),
        _ => _photoPills(),
      };

      // The strip row anchors at the bottom; the slider bubble grows upward
      // above it (a transient overlay — it may float over the lens tray).
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: switch (_bubble) {
              _Bubble.exposure => _SliderBubble(
                  key: const ValueKey('bubble_ev'),
                  label: 'EV',
                  child: Watch((context) {
                    final ev = cameraStore.exposure.value;
                    return _BubbleSlider(
                      value: ev,
                      min: -4,
                      max: 4,
                      valueLabel: _evLabel(ev),
                      onChanged: (v) {
                        // 0-detent: snap flat near the neutral point.
                        final snapped = v.abs() < 0.15 ? 0.0 : v;
                        if (snapped != ev) {
                          if (snapped == 0.0) {
                            HapticFeedback.selectionClick();
                          }
                          cameraStore.setExposure(snapped);
                        }
                        _armDismiss();
                      },
                    );
                  }),
                ),
              _Bubble.torch => _SliderBubble(
                  key: const ValueKey('bubble_torch'),
                  label: 'TORCH',
                  child: Watch((context) {
                    final level = cameraStore.torchLevel.value;
                    return _BubbleSlider(
                      value: level,
                      min: 0,
                      max: 1,
                      valueLabel: '${(level * 100).round()}%',
                      onChanged: (v) {
                        cameraStore.setTorchLevel(v);
                        _armDismiss();
                      },
                    );
                  }),
                ),
              _Bubble.none =>
                const SizedBox.shrink(key: ValueKey('bubble_none')),
            },
          ),
          SizedBox(
            height: ProStrip.kPillHeight,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: SingleChildScrollView(
                key: ValueKey('pro_strip_$mode'),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, pill) in pills.indexed) ...[
                      if (i > 0) const SizedBox(width: 8),
                      pill,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// One glass pill: icon + tiny label, cyan when active, haptic on tap.
class _ProPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ProPill({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.black : Colors.white70;
    return GlassTooltip(
      message: tooltip,
      preferBelow: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              height: ProStrip.kPillHeight,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: active
                    ? Colors.cyanAccent
                    : Colors.black.withValues(alpha: 0.40),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: active
                      ? Colors.cyanAccent
                      : Colors.white.withValues(alpha: 0.10),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact glass bubble hosting a slider, shown above the strip.
class _SliderBubble extends StatelessWidget {
  final String label;
  final Widget child;
  const _SliderBubble({super.key, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: 300,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4,
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Slim slider + trailing value readout used inside [_SliderBubble].
class _BubbleSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  const _BubbleSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.valueLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              activeColor: Colors.cyanAccent,
              inactiveColor: Colors.white24,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            valueLabel,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ],
    );
  }
}
