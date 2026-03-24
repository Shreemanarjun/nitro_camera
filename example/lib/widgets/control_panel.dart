import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'dart:ui' as ui;

enum CameraStatus { closed, opening, closing, running, error }

class ControlPanel extends StatelessWidget {
  final CameraStatus status;
  final bool isProcessing;
  final ValueChanged<CameraDevice> onSelectDevice;
  final ValueChanged<bool> onToggleProcessing;
  final List<CameraDevice> devices;
  final CameraDevice? selectedDevice;
  final int selectedWidth;
  final int selectedFps;
  final Function(int, int) onResolutionChanged;
  final ValueChanged<int> onFpsChanged;
  final VoidCallback onTakePhoto;
  final VoidCallback onToggleRecording;
  final bool isRecording;

  const ControlPanel({
    super.key,
    required this.status,
    required this.isProcessing,
    required this.onSelectDevice,
    required this.onToggleProcessing,
    required this.devices,
    required this.selectedDevice,
    required this.selectedWidth,
    required this.selectedFps,
    required this.onResolutionChanged,
    required this.onFpsChanged,
    required this.onTakePhoto,
    required this.onToggleRecording,
    required this.isRecording,
  });

  @override
  Widget build(BuildContext context) {
    final isRunning = status == CameraStatus.running;
    final isChanging = status == CameraStatus.opening || status == CameraStatus.closing;

    return ClipRRect(
      borderRadius: BorderRadius.circular(35),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(35),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Device Wrap
              const _SectionTitle(title: 'ORIENTATION / SENSOR'),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: devices.map((d) {
                    final group = d.position == 1 ? "BACK" : (d.position == 2 ? "FRONT" : "EXT");
                    final isSelected = selectedDevice?.id == d.id;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text("$group: ${d.name}", 
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isSelected ? Colors.black : Colors.white)),
                        selected: isSelected,
                        onSelected: isChanging ? null : (_) => onSelectDevice(d),
                        selectedColor: Colors.cyanAccent,
                        backgroundColor: Colors.white10,
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 20),

              // 2. Res & FPS
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionTitle(title: 'RESOLUTION'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            _ChoiceBtn(
                              label: '720P',
                              isSelected: selectedWidth == 1280,
                              onTap: () => onResolutionChanged(1280, 720),
                            ),
                            _ChoiceBtn(
                              label: '1080P',
                              isSelected: selectedWidth == 1920,
                              onTap: () => onResolutionChanged(1920, 1080),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionTitle(title: 'FRAME RATE'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            _ChoiceBtn(
                              label: '30 FPS',
                              isSelected: selectedFps == 30,
                              onTap: () => onFpsChanged(30),
                            ),
                            _ChoiceBtn(
                              label: '60 FPS',
                              isSelected: selectedFps == 60,
                              onTap: () => onFpsChanged(60),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 25),

              // 3. Action Bar
              Row(
                children: [
                  if (isRunning) ...[
                    _ControlCircleButton(
                      onTap: onTakePhoto,
                      icon: Icons.camera_rounded,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 15),
                    _ControlCircleButton(
                      onTap: onToggleRecording,
                      icon: isRecording ? Icons.stop_rounded : Icons.videocam_rounded,
                      color: isRecording ? Colors.redAccent : Colors.white,
                      isPulse: isRecording,
                    ),
                  ],
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('STREAM', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                      Switch(
                        value: isProcessing,
                        onChanged: isRunning ? onToggleProcessing : null,
                        activeThumbColor: Colors.cyanAccent,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});
  @override
  Widget build(BuildContext context) => Text(
    title,
    style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.5),
  );
}

class _ChoiceBtn extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  const _ChoiceBtn({required this.label, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyanAccent : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _ControlCircleButton extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final Color color;
  final bool isPulse;

  const _ControlCircleButton({required this.onTap, required this.icon, required this.color, this.isPulse = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
    );
  }
}
