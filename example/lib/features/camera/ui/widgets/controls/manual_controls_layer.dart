import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';
import '../../theme/app_theme.dart';

/// On-preview interactive manual controls — the easy-to-use replacement for the
/// raw FOCUS/SHUTTER/ISO sliders that used to be buried in the advanced sheet.
///
///  * a vertical **rack-focus rail** on the right edge (drag between macro and
///    ∞, live), and
///  * tappable **shutter / ISO stop wheels** along the bottom.
///
/// Shown only while [CameraStore.manualPanelOpen] is on (toggled by the MANUAL
/// pill). Everything drives the same [CameraController] setters the sliders did.
class ManualControlsLayer extends StatelessWidget {
  const ManualControlsLayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Returns a plain Stack (no Positioned root) so it can sit under
    // _HideWhileRecording; the caller wraps it in Positioned.fill.
    return Watch((context) {
      // Only meaningful in PHOTO/VIDEO — the pill that opens it lives there.
      final mode = cameraStore.mode.value;
      if (!cameraStore.manualPanelOpen.value || mode == 'SCANNER') {
        return const SizedBox.shrink();
      }
      return const Stack(
        children: [
          // Rack-focus rail — right edge, anchored in the upper region so it
          // stays clear of the exposure wheels below (bottom: 300 reserves that
          // band for the wheels + chrome).
          Positioned(right: 12, top: 0, bottom: 300, child: Center(child: _FocusRail())),
          // Exposure wheels sit clear ABOVE the bottom chrome (pro-strip pills
          // + mode tabs + capture row, ~235 pt of fixed bottom-anchored UI).
          Positioned(left: 0, right: 0, bottom: 248, child: _ExposureWheels()),
        ],
      );
    });
  }
}

/// A vertical drag rail: top = far (∞, distance 0), bottom = near (🌷, 1).
class _FocusRail extends StatelessWidget {
  const _FocusRail();
  static const double _h = 240;

  void _setFromDy(double dy) =>
      cameraStore.setFocusDistance((dy / _h).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final fd = cameraStore.focusDistance.value;
      final manual = fd >= 0;
      final frac = manual ? fd : 0.0;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // AF reset — bright when auto, dim when manual is engaged.
          GestureDetector(
            onTap: () => cameraStore.setFocusDistance(-1),
            behavior: HitTestBehavior.opaque,
            child: _Bubble(
              label: 'AF',
              active: !manual,
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) => _setFromDy(d.localPosition.dy),
            onTapDown: (d) => _setFromDy(d.localPosition.dy),
            child: SizedBox(
              width: 44,
              height: _h,
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  // Track.
                  Center(
                    child: Container(
                      width: 3,
                      height: _h,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Positioned(
                    top: 2,
                    child: Icon(Icons.landscape_rounded, size: 16, color: Colors.white54),
                  ),
                  const Positioned(
                    bottom: 2,
                    child: Icon(Icons.local_florist_rounded, size: 16, color: Colors.white54),
                  ),
                  // Thumb.
                  Positioned(
                    top: (frac * _h).clamp(0.0, _h) - 9,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: manual ? AppColors.accent : Colors.white70,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _Bubble(
            label: manual ? fd.toStringAsFixed(2) : 'AUTO',
            active: manual,
          ),
        ],
      );
    });
  }
}

/// Two horizontal stop-wheels (SHUTTER, ISO) — one tap per stop, far easier
/// than dragging a 4..8000 denominator slider.
class _ExposureWheels extends StatelessWidget {
  const _ExposureWheels();

  // Shutter denominators (AUTO = 0).
  static const _shutter = <int>[0, 30, 60, 125, 250, 500, 1000, 2000, 4000];
  static const _iso = <int>[0, 50, 100, 200, 400, 800, 1600, 3200];

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final ns = cameraStore.manualShutterNs.value;
      final curDenom = ns <= 0 ? 0 : (1e9 / ns).round();
      final iso = cameraStore.manualIso.value;
      final curIso = iso <= 0 ? 0 : iso.round();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Wheel(
            title: 'SHUTTER',
            stops: _shutter,
            selected: curDenom,
            label: (d) => d == 0 ? 'AUTO' : '1/$d',
            isSelected: (d) => d == 0 ? ns <= 0 : (curDenom == d),
            onTap: (d) => d == 0
                ? cameraStore.setAutoExposure()
                : cameraStore.setManualShutter(1e9 / d),
          ),
          const SizedBox(height: 8),
          _Wheel(
            title: 'ISO',
            stops: _iso,
            selected: curIso,
            label: (v) => v == 0 ? 'AUTO' : '$v',
            isSelected: (v) => v == 0 ? iso <= 0 : (curIso == v),
            onTap: (v) => v == 0
                ? cameraStore.setAutoExposure()
                : cameraStore.setManualIso(v.toDouble()),
          ),
        ],
      );
    });
  }
}

class _Wheel extends StatelessWidget {
  final String title;
  final List<int> stops;
  final int selected;
  final String Function(int) label;
  final bool Function(int) isSelected;
  final ValueChanged<int> onTap;
  const _Wheel({
    required this.title,
    required this.stops,
    required this.selected,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.visible,
              softWrap: false,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 16),
              children: [
                for (final s in stops)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => onTap(s),
                      behavior: HitTestBehavior.opaque,
                      child: _Bubble(
                        label: label(s),
                        active: isSelected(s),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Small solid capsule used across the manual layer. A flat translucent scrim
/// (NOT a per-chip BackdropFilter): the layer shows ~19 of these at once, and
/// stacking that many backdrop blurs is the main cause of switching jank — on a
/// chip this small a blur is invisible anyway. The fill is a touch more opaque
/// than the old frosted look to stay legible over the live preview.
class _Bubble extends StatelessWidget {
  final String label;
  final bool active;
  const _Bubble({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: active
            ? AppColors.accent.withValues(alpha: 0.24)
            : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active ? AppColors.accent : Colors.white24,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? AppColors.accent : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
