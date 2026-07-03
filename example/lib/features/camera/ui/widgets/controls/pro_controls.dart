import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';
import 'session_panel.dart';

/// Advanced controls sheet — exercises the full [CameraController] API surface:
/// exposure (+lock), white balance (+lock), auto-focus mode (+lock), HDR,
/// low-light boost, torch level, video stabilization, photo quality, target
/// orientation, snapshot, plus the resolved-config / session-state / event
/// read-backs.
class ProControlsSheet extends StatelessWidget {
  const ProControlsSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Never let the sheet grow under the status bar / notch.
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.9,
    ),
    builder: (_) => const ProControlsSheet(),
  );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          // Keep the close button (and everything else) clear of the status bar.
          child: SafeArea(
            top: true,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 28),
                        const Spacer(),
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.of(context).maybePop(),
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              color: Colors.white54,
                              size: 22,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const ProControlsBody(),
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

/// The PRO controls content — embeddable in any container (used by the merged
/// [SettingsSheet] as well as the standalone [ProControlsSheet]).
class ProControlsBody extends StatelessWidget {
  const ProControlsBody({super.key});

  @override
  Widget build(BuildContext context) {
    final s = cameraStore;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Exposure
        Watch((_) {
          final dev = s.currentDevice.value;
          return _SliderRow(
            label: 'EXPOSURE',
            value: s.exposure.value,
            min: dev?.minExposure ?? -2,
            max: dev?.maxExposure ?? 2,
            display: s.exposure.value.toStringAsFixed(1),
            onChanged: s.setExposure,
            trailing: _LockChip(
              locked: s.exposureLocked.value,
              onTap: () => s.lockExposure(!s.exposureLocked.value),
            ),
          );
        }),

        // White balance
        Watch((_) {
          final k = s.whiteBalanceKelvin.value;
          return _SliderRow(
            label: 'WHITE BALANCE',
            value: (k == 0 ? 5000 : k).toDouble(),
            min: 2000,
            max: 8000,
            display: k == 0 ? 'AUTO' : '${k}K',
            onChanged: (v) => s.setWhiteBalance(v.round()),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MiniBtn('AUTO', () => s.setWhiteBalance(0)),
                const SizedBox(width: 6),
                _LockChip(
                  locked: s.whiteBalanceLocked.value,
                  onTap: () => s.lockWhiteBalance(!s.whiteBalanceLocked.value),
                ),
              ],
            ),
          );
        }),

        // Torch level
        Watch(
          (_) => _SliderRow(
            label: 'TORCH LEVEL',
            value: s.torchLevel.value,
            min: 0,
            max: 1,
            display: '${(s.torchLevel.value * 100).round()}%',
            onChanged: s.setTorchLevel,
          ),
        ),

        const Divider(color: Colors.white12, height: 28),

        // Auto-focus mode
        Watch(
          (_) => _SegmentRow<AutoFocusMode>(
            label: 'AUTO FOCUS',
            value: s.autoFocusMode.value,
            options: const {
              AutoFocusMode.off: 'OFF',
              AutoFocusMode.continuous: 'CONT',
              AutoFocusMode.locked: 'LOCK',
            },
            onChanged: s.setAutoFocus,
            trailing: _LockChip(
              locked: s.focusLocked.value,
              onTap: () => s.lockFocus(!s.focusLocked.value),
            ),
          ),
        ),

        // Video stabilization
        Watch(
          (_) => _SegmentRow<int>(
            label: 'STABILIZATION',
            value: s.videoStabilization.value,
            options: const {0: 'OFF', 1: 'STD', 2: 'CINE'},
            onChanged: s.setVideoStabilization,
          ),
        ),

        // Photo quality
        Watch(
          (_) => _SegmentRow<QualityPrioritization>(
            label: 'PHOTO QUALITY',
            value: s.photoQuality.value,
            options: const {
              QualityPrioritization.speed: 'SPEED',
              QualityPrioritization.balanced: 'BAL',
              QualityPrioritization.quality: 'QUAL',
            },
            onChanged: (v) => s.photoQuality.value = v,
          ),
        ),

        // Target orientation (-1 = follow device rotation)
        Watch(
          (_) => _SegmentRow<int>(
            label: 'ORIENTATION',
            value: s.targetOrientation.value,
            options: const {
              -1: 'AUTO',
              0: '0°',
              90: '90°',
              180: '180°',
              270: '270°',
            },
            onChanged: s.setTargetOrientation,
          ),
        ),

        const Divider(color: Colors.white12, height: 28),

        // Toggles
        Watch(
          (_) => _ToggleRow(
            label: 'HDR',
            value: s.hdrEnabled.value,
            onChanged: s.setHdr,
          ),
        ),
        Watch(
          (_) => _ToggleRow(
            label: 'LOW-LIGHT BOOST',
            value: s.lowLightBoost.value,
            onChanged: s.setLowLightBoost,
          ),
        ),
        Watch(
          (_) => _ToggleRow(
            label: 'TORCH',
            value: s.torch.value,
            onChanged: s.setTorch,
          ),
        ),

        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: s.takeSnapshot,
          icon: const Icon(Icons.bolt, size: 16),
          label: const Text('TAKE SNAPSHOT'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.cyanAccent,
            side: const BorderSide(color: Colors.cyanAccent),
          ),
        ),

        const Divider(color: Colors.white12, height: 28),
        const SessionPanel(),
      ],
    );
  }
}

class _LabelRow extends StatelessWidget {
  final String label;
  final Widget child;
  final Widget? trailing;
  const _LabelRow({required this.label, required this.child, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
            ?trailing,
          ],
        ),
        child,
      ],
    ),
  );
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value, min, max;
  final String display;
  final ValueChanged<double> onChanged;
  final Widget? trailing;
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) => _LabelRow(
    label: '$label   ·   $display',
    trailing: trailing,
    child: SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        activeTrackColor: Colors.cyanAccent,
        inactiveTrackColor: Colors.white10,
        thumbColor: Colors.cyanAccent,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    ),
  );
}

class _SegmentRow<T> extends StatelessWidget {
  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final Widget? trailing;
  const _SegmentRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) => _LabelRow(
    label: label,
    trailing: trailing,
    child: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: options.entries.map((e) {
          final sel = e.key == value;
          return GestureDetector(
            onTap: () => onChanged(e.key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: sel
                    ? Colors.cyanAccent.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: sel ? Colors.cyanAccent : Colors.white12,
                ),
              ),
              child: Text(
                e.value,
                style: TextStyle(
                  color: sel ? Colors.cyanAccent : Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    ),
  );
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeThumbColor: Colors.cyanAccent,
        activeTrackColor: Colors.cyanAccent.withValues(alpha: 0.2),
      ),
    ],
  );
}

class _LockChip extends StatelessWidget {
  final bool locked;
  final VoidCallback onTap;
  const _LockChip({required this.locked, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Icon(
      locked ? Icons.lock : Icons.lock_open,
      size: 16,
      color: locked ? Colors.amberAccent : Colors.white38,
    ),
  );
}

class _MiniBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MiniBtn(this.label, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.cyanAccent,
        fontSize: 9,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}
