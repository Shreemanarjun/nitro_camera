import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controls/control_panel.dart' show ConfigBody;
import '../controls/pro_controls.dart' show ProControlsBody;

/// The unified settings surface: PRO (full controller API — exposure, WB,
/// focus, stabilization, orientation, toggles, session read-backs) and CONFIG
/// (hardware sensor, quality/fps, engine, codec, preview fit) live in ONE
/// sheet behind a segmented switch instead of two separate entry points.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, this.initialTab = SettingsTab.pro});

  final SettingsTab initialTab;

  static Future<void> show(
    BuildContext context, {
    SettingsTab initialTab = SettingsTab.pro,
  }) =>
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        // Never let the sheet grow under the status bar / notch.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        builder: (_) => SettingsSheet(initialTab: initialTab),
      );

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

enum SettingsTab { pro, config }

class _SettingsSheetState extends State<SettingsSheet> {
  late SettingsTab _tab = widget.initialTab;

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
          child: SafeArea(
            top: true,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Drag handle + close.
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
                          child:
                              Icon(Icons.close, color: Colors.white54, size: 22),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // PRO | CONFIG segmented switch.
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _segment('PRO', Icons.tune, SettingsTab.pro),
                          _segment('CONFIG', Icons.settings_input_component,
                              SettingsTab.config),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Active section.
                  Flexible(
                    child: SingleChildScrollView(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: SizeTransition(
                            sizeFactor: anim,
                            alignment: const AlignmentDirectional(0, -1),
                            child: child,
                          ),
                        ),
                        child: _tab == SettingsTab.pro
                            ? const KeyedSubtree(
                                key: ValueKey('pro'),
                                child: ProControlsBody(),
                              )
                            : const KeyedSubtree(
                                key: ValueKey('config'),
                                child: ConfigBody(),
                              ),
                      ),
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

  Widget _segment(String label, IconData icon, SettingsTab tab) {
    final selected = _tab == tab;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _tab = tab);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.cyanAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: selected ? Colors.black : Colors.white60),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white60,
                fontSize: 11,
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
