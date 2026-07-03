import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';

/// FRONT/BACK category selector + per-side lens circles (vision-camera-style
/// device categories with relative-zoom labels).
class SensorTray extends StatelessWidget {
  const SensorTray({super.key});

  void _selectCategory(List<CameraDeviceInfo> cams) {
    if (cams.isEmpty) return;
    // Prefer the 1.0× baseline lens of the chosen side.
    final baseline = cams.firstWhere(
      (d) => d.lensType == 1,
      orElse: () => cams.first,
    );
    cameraStore.selectDevice(baseline);
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final devices = cameraStore.devices.value;
      final currentDevice = cameraStore.currentDevice.value;
      if (devices.isEmpty) return const SizedBox.shrink();

      final backCameras = devices.where((d) => d.position == 1).toList();
      final frontCameras = devices.where((d) => d.position == 0).toList();
      final isFront = currentDevice?.position == 0;
      final activeCameras = (isFront ? frontCameras : backCameras);

      final baselineLens = backCameras.firstWhere(
        (d) => d.lensType == 1,
        orElse: () =>
            backCameras.isNotEmpty ? backCameras.first : devices.first,
      );
      final baselineFocal = baselineLens.focalLength;

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. FRONT / BACK category selector (only when both exist).
          if (backCameras.isNotEmpty && frontCameras.isNotEmpty)
            _CategoryTabs(
              isFront: isFront,
              onBack: () => _selectCategory(backCameras),
              onFront: () => _selectCategory(frontCameras),
            ),
          const SizedBox(height: 12),

          // 2. Lens / zoom options for the active category.
          SizedBox(
            height: 60,
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: activeCameras.map((d) {
                    final isSelected = currentDevice?.id == d.id;

                    String label;
                    if (d.position == 0) {
                      // Front side: distinguish multiple front lenses if present.
                      label = frontCameras.length > 1
                          ? "${(d.focalLength / (frontCameras.first.focalLength)).toStringAsFixed(1)}×"
                          : "SELF";
                    } else {
                      final relZoom = d.focalLength / baselineFocal;
                      label = relZoom > 0.9 && relZoom < 1.1
                          ? "1.0×"
                          : "${relZoom.toStringAsFixed(1)}×";
                    }

                    return GestureDetector(
                      onTap: () => cameraStore.selectDevice(d),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: isSelected ? 54 : 44,
                        height: isSelected ? 54 : 44,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color:
                              isSelected ? Colors.amberAccent : Colors.black45,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? Colors.white : Colors.white24,
                            width: isSelected ? 2 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: Colors.amberAccent
                                        .withValues(alpha: 0.4),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : [],
                        ),
                        child: Center(
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color:
                                  isSelected ? Colors.black : Colors.white70,
                              fontSize: isSelected ? 11 : 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// FRONT / BACK segmented selector.
class _CategoryTabs extends StatelessWidget {
  final bool isFront;
  final VoidCallback onBack;
  final VoidCallback onFront;
  const _CategoryTabs({
    required this.isFront,
    required this.onBack,
    required this.onFront,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tab('BACK', Icons.camera_rear, !isFront, onBack),
              _tab('FRONT', Icons.camera_front, isFront, onFront),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(String label, IconData icon, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.cyanAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: selected ? Colors.black : Colors.white60),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white60,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
