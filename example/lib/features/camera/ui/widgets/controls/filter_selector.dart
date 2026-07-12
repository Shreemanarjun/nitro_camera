import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import '../../../state/camera_store.dart';

class FilterSelector extends StatelessWidget {
  final Map<String, String>? filters;
  final String? currentFilterName;
  final Function(String)? onFilterSelected;

  const FilterSelector({
    super.key,
    this.filters,
    this.currentFilterName,
    this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final activeFilters = filters ?? CameraStore.filters;
      final activeCurrentName =
          currentFilterName ?? cameraStore.currentFilterName.value;
      final filterNames = activeFilters.keys.toList();

      return Container(
        height: 80,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: filterNames.length,
          itemBuilder: (context, index) {
            final name = filterNames[index];
            final isSelected = name == activeCurrentName;

            return GestureDetector(
              onTap: () {
                if (onFilterSelected != null) {
                  onFilterSelected!(name);
                } else {
                  cameraStore.setFilter(name);
                }
              },
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? Colors.cyanAccent
                              : Colors.white24,
                          width: isSelected ? 2 : 1,
                        ),
                        gradient: _getFilterGradient(name),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: Colors.cyanAccent.withValues(
                                    alpha: 0.3,
                                  ),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: isSelected
                          ? const Icon(
                              Icons.check,
                              color: Colors.cyanAccent,
                              size: 16,
                            )
                          : null,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      name,
                      style: TextStyle(
                        color: isSelected ? Colors.cyanAccent : Colors.white60,
                        fontSize: 8,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    });
  }

  LinearGradient _getFilterGradient(String name) {
    switch (name) {
      case 'INVERT':
        return const LinearGradient(colors: [Colors.black, Colors.white]);
      case 'GRAYSCALE':
        return const LinearGradient(colors: [Colors.grey, Colors.blueGrey]);
      case 'SEPIA':
        return const LinearGradient(
          colors: [Color(0xFF704214), Color(0xFFC0A080)],
        );
      case 'VIGNETTE':
        return const LinearGradient(
          colors: [Colors.black, Colors.transparent],
          begin: Alignment.center,
          end: Alignment.bottomRight,
        );
      default:
        return LinearGradient(
          colors: [
            Colors.cyanAccent.withValues(alpha: 0.2),
            Colors.cyanAccent.withValues(alpha: 0.6),
          ],
        );
    }
  }
}
