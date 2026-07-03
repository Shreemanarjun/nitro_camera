import 'package:flutter/material.dart';

/// Dark-glass tooltip used by every icon control in the camera UI (top strip,
/// bottom cluster, lens chips, scanner chips) so long-press hints look like
/// one system. Long-press shows the tooltip (Flutter default); taps pass
/// straight through to the wrapped gesture target, so it never fights the
/// controls' own [GestureDetector]s.
class GlassTooltip extends StatelessWidget {
  final String message;

  /// Top-strip controls prefer the balloon below; bottom controls above.
  final bool preferBelow;
  final Widget child;

  const GlassTooltip({
    super.key,
    required this.message,
    required this.child,
    this.preferBelow = true,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      preferBelow: preferBelow,
      verticalOffset: 18,
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
      child: child,
    );
  }
}
