import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';
import 'filter_selector.dart';
import 'pro_strip.dart';
import 'sensor_tray.dart';

/// The bottom tray region above the main controls: the mode-aware PRO strip
/// (contextual pro-setting pills, directly above the mode tabs), the sensor
/// tray (BACK/FRONT category tabs + lens chips) and the collapsible filter
/// tray.
///
/// The trays are mutually exclusive with the filter tray — opening it slides
/// the sensor tray down and out of the layout and hides the PRO strip, so
/// their interactive controls can never overlap in any mode
/// (PHOTO/VIDEO/SCANNER).
class TrayLayer extends StatelessWidget {
  const TrayLayer({super.key});

  static const _kAnim = Duration(milliseconds: 260);
  static const _kCurve = Curves.easeOutCubic;

  /// Bottom inset of the tray region (just above the bottom controls).
  static const double kTrayBottom = 200;

  /// Vertical room reserved for the PRO strip (pill row + breathing space);
  /// the sensor tray sits above it so the two never overlap.
  static const double kProStripSlot = ProStrip.kPillHeight + 12;

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final showFilters = cameraStore.showFilters.value;
      return Stack(
        children: [
          // Sensor tray — slides fully below the screen edge while the filter
          // tray is open (a real layout offset, not just a paint transform,
          // so nothing invisible keeps swallowing touches).
          AnimatedPositioned(
            duration: _kAnim,
            curve: _kCurve,
            bottom: showFilters ? -180 : kTrayBottom + kProStripSlot,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: _kAnim,
              curve: _kCurve,
              opacity: showFilters ? 0.0 : 1.0,
              child: IgnorePointer(
                ignoring: showFilters,
                child: const SensorTray(),
              ),
            ),
          ),

          // PRO strip — mode-aware pro-setting pills directly above the mode
          // tabs. Slides down + fades while the filter tray is open (real
          // layout offset + IgnorePointer, same recipe as the sensor tray).
          AnimatedPositioned(
            duration: _kAnim,
            curve: _kCurve,
            bottom: showFilters ? -60 : kTrayBottom,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: _kAnim,
              curve: _kCurve,
              opacity: showFilters ? 0.0 : 1.0,
              child: IgnorePointer(
                ignoring: showFilters,
                child: const ProStrip(),
              ),
            ),
          ),

          // Filter tray — takes over the vacated tray region when open.
          AnimatedPositioned(
            duration: _kAnim,
            curve: _kCurve,
            bottom: showFilters ? kTrayBottom + 10 : kTrayBottom - 50,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: _kAnim,
              curve: _kCurve,
              opacity: showFilters ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !showFilters,
                child: const FilterSelector(),
              ),
            ),
          ),
        ],
      );
    });
  }
}
