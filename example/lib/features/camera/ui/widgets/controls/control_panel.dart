import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'dart:ui' as ui;
import '../../../state/camera_store.dart';

class ControlPanel extends StatelessWidget {
  const ControlPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final status = cameraStore.status.value;
      final isProcessing = cameraStore.isProcessingFrames.value;
      final devices = cameraStore.devices.value;
      final selectedDevice = cameraStore.currentDevice.value;
      final selectedWidth = cameraStore.width.value;
      final selectedFps = cameraStore.fps.value;
      final pixelFormat = cameraStore.pixelFormat.value;
      final samplingRate = cameraStore.samplingRate.value;
      final videoStab = cameraStore.videoStabilization.value;

      final isRunning = status == CameraStatus.running;
      final isChanging = status == CameraStatus.opening || status == CameraStatus.closing;

      return Material(
        type: MaterialType.transparency,
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            margin: const EdgeInsets.symmetric(horizontal: 24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(40),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const _PanelHeader(icon: Icons.settings_input_component, title: "CONFIG"),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close, color: Colors.white24, size: 20),
                          )
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 1. Devices
                      const _PanelHeader(icon: Icons.sensors, title: "HARDWARE SENSORS"),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: devices.map((d) {
                            final isSelected = selectedDevice?.id == d.id;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _PremiumChip(
                                label: d.name,
                                isSelected: isSelected,
                                onPressed: isChanging ? null : () => cameraStore.selectDevice(d),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // 2. Format & Performance
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _PanelHeader(icon: Icons.hd_outlined, title: "QUALITY"),
                                const SizedBox(height: 12),
                                Wrap(spacing: 8, runSpacing: 8, children: [
                                  _ChoiceBtn(label: '720', isSelected: selectedWidth == 1280, onTap: () => cameraStore.setResolution(1280, 720)),
                                  _ChoiceBtn(label: '1080', isSelected: selectedWidth == 1920, onTap: () => cameraStore.setResolution(1920, 1080)),
                                ]),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _PanelHeader(icon: Icons.speed, title: "FPS"),
                                const SizedBox(height: 12),
                                Wrap(spacing: 8, runSpacing: 8, children: [
                                  _ChoiceBtn(label: '30', isSelected: selectedFps == 30, onTap: () => cameraStore.setFps(30)),
                                  _ChoiceBtn(label: '60', isSelected: selectedFps == 60, onTap: () => cameraStore.setFps(60)),
                                ]),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 3. Stream Controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _PanelHeader(icon: Icons.hub_outlined, title: "NITRO ENGINE"),
                                const SizedBox(height: 12),
                                Wrap(spacing: 8, children: [
                                  _ChoiceBtn(label: 'YUV', isSelected: pixelFormat == 0, onTap: () => cameraStore.setPixelFormat(0)),
                                  _ChoiceBtn(label: 'BGRA', isSelected: pixelFormat == 1, onTap: () => cameraStore.setPixelFormat(1)),
                                ]),
                              ],
                            ),
                          ),
                          _StreamToggle(
                            isActive: isProcessing,
                            onChanged: isRunning ? cameraStore.toggleProcessing : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 4. Sampling Rate
                      const _PanelHeader(icon: Icons.alt_route, title: "ANALYSIS SAMPLING"),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Watch((context) => SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2,
                                activeTrackColor: Colors.cyanAccent,
                                inactiveTrackColor: Colors.white10,
                                thumbColor: Colors.cyanAccent,
                                overlayColor: Colors.cyanAccent.withValues(alpha: 0.1),
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              ),
                              child: Slider(
                                value: samplingRate.toDouble(),
                                min: 1,
                                max: 30,
                                divisions: 29,
                                onChanged: isRunning ? (v) => cameraStore.setSamplingRate(v.toInt()) : null,
                              ),
                            )),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            "EVERY $samplingRate'th FRAME",
                            style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 5. Video stabilization (new nitro API)
                      const _PanelHeader(icon: Icons.vibration, title: "STABILIZATION"),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        _ChoiceBtn(label: 'OFF', isSelected: videoStab == 0, onTap: () => cameraStore.setVideoStabilization(0)),
                        _ChoiceBtn(label: 'STANDARD', isSelected: videoStab == 1, onTap: () => cameraStore.setVideoStabilization(1)),
                        _ChoiceBtn(label: 'CINEMATIC', isSelected: videoStab == 2, onTap: () => cameraStore.setVideoStabilization(2)),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _PanelHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _PanelHeader({required this.icon, required this.title});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: Colors.cyanAccent.withValues(alpha: 0.6), size: 10),
      const SizedBox(width: 8),
      Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.3),
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
        ),
      ),
    ],
  );
}

class _PremiumChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback? onPressed;
  const _PremiumChip({required this.label, required this.isSelected, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyanAccent : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? Colors.cyanAccent : Colors.white.withValues(alpha: 0.1)),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white60,
            fontSize: 8,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyanAccent.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? Colors.cyanAccent : Colors.white.withValues(alpha: 0.05)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.cyanAccent : Colors.white38,
            fontSize: 9,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _StreamToggle extends StatelessWidget {
  final bool isActive;
  final ValueChanged<bool>? onChanged;
  const _StreamToggle({required this.isActive, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch.adaptive(
          value: isActive,
          onChanged: onChanged,
          activeThumbColor: Colors.cyanAccent,
          activeTrackColor: Colors.cyanAccent.withValues(alpha: 0.2),
        ),
      ],
    );
  }
}
