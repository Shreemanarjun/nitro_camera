import 'package:flutter/material.dart';

import '../bench_theme.dart';

/// One segment of the ZXing / ML Kit engine picker.
class EngineToggle extends StatelessWidget {
  const EngineToggle({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap; // null while a run is active

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? benchAccent : benchScrim,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
