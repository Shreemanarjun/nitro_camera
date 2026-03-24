import 'package:flutter/material.dart';

class FilterSelector extends StatelessWidget {
  final Map<String, String> filters;
  final String currentFilterName;
  final Function(String) onFilterSelected;

  const FilterSelector({
    super.key,
    required this.filters,
    required this.currentFilterName,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 100,
      margin: const EdgeInsets.only(bottom: 20),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: filters.length,
        itemBuilder: (context, index) {
          final entry = filters.entries.elementAt(index);
          final isSelected = entry.key == currentFilterName;
          return GestureDetector(
            onTap: () => onFilterSelected(entry.key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 80,
              margin: const EdgeInsets.only(right: 15),
              decoration: BoxDecoration(
                color: isSelected ? Colors.cyanAccent : Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isSelected ? Colors.cyanAccent : Colors.white10),
                boxShadow: isSelected ? [
                  BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.3), blurRadius: 15, spreadRadius: -5)
                ] : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isSelected ? Icons.auto_awesome : Icons.palette_outlined,
                    color: isSelected ? Colors.black : Colors.white70,
                    size: 28,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    entry.key,
                    style: TextStyle(
                      color: isSelected ? Colors.black : Colors.white70,
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
