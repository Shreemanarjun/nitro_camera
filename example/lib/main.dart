import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(
    MaterialApp(
      home: const _CameraApp(),
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyanAccent,
          brightness: Brightness.dark,
          surface: Colors.black,
        ),
      ),
    ),
  );
}

class _CameraApp extends StatefulWidget {
  const _CameraApp();

  @override
  State<_CameraApp> createState() => _CameraAppState();
}

enum CameraStatus { closed, opening, closing, running, error }

class _CameraAppState extends State<_CameraApp> with WidgetsBindingObserver {
  int? _textureId;
  bool _isProcessingFrames = false;
  CameraDevice? _currentDevice;
  List<CameraDevice> _devices = [];
  bool _loading = true;
  String? _errorMessage;
  CameraStatus _status = CameraStatus.closed;
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_textureId != null) {
      NitroCamera.instance.closeCamera(_textureId!);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (_textureId != null) _toggleCamera(); // Auto-close on pause
    }
  }

  Future<void> _init() async {
    try {
      final status = await NitroCamera.instance.getCameraPermissionStatus();
      if (status != 1) {
        await NitroCamera.instance.requestCameraPermission();
      }

      final count = await NitroCamera.instance.getDeviceCount();
      final devices = <CameraDevice>[];
      for (var i = 0; i < count; i++) {
        devices.add(await NitroCamera.instance.getDevice(i));
      }

      if (mounted) {
        setState(() {
          _devices = devices;
          if (devices.isNotEmpty) {
            _currentDevice = devices.firstWhere(
              (d) => d.position == 1, // Back
              orElse: () => devices.first,
            );
          }
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _loading = false;
      });
    }
  }

  bool _isToggling = false;

  Future<void> _toggleCamera() async {
    if (_isToggling) return;
    _isToggling = true;
    _errorMessage = null;

    try {
      if (_textureId != null) {
        setState(() => _status = CameraStatus.closing);
        await NitroCamera.instance.closeCamera(_textureId!);
        setState(() {
          _textureId = null;
          _status = CameraStatus.closed;
          _isProcessingFrames = false;
          _isRecording = false;
        });
      } else {
        if (_currentDevice == null) return;
        setState(() => _status = CameraStatus.opening);
        final id = await NitroCamera.instance.openCamera(
          _currentDevice!.id,
          1280, // Requesting 720p for best balance of quality/perf
          720,
          30,
          0,
        );
        setState(() {
          _textureId = id;
          _status = CameraStatus.running;
        });
      }
    } catch (e) {
      setState(() {
        _status = CameraStatus.error;
        _errorMessage = e.toString();
      });
    } finally {
      _isToggling = false;
    }
  }

  bool _isActionBusy = false;

  Future<void> _takePhoto() async {
    if (_textureId == null || _isActionBusy) return;
    _isActionBusy = true;
    try {
      final result = await NitroCamera.instance.takePhoto(_textureId!);
      _showToast('Photo captured: ${result.path.split('/').last}', Colors.greenAccent);
    } catch (e) {
      _showToast('Capture error: $e', Colors.redAccent);
    } finally {
      _isActionBusy = false;
    }
  }

  Future<void> _toggleRecording() async {
    if (_textureId == null || _isActionBusy) return;
    _isActionBusy = true;
    try {
      if (_isRecording) {
        final result = await NitroCamera.instance.stopVideoRecording(_textureId!);
        setState(() => _isRecording = false);
        _showToast('Video saved: ${result.path.split('/').last}', Colors.cyanAccent);
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/nitro_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await NitroCamera.instance.startVideoRecording(_textureId!, path);
        setState(() => _isRecording = true);
        _showToast('Recording started...', Colors.orangeAccent);
      }
    } catch (e) {
      _showToast('Video error: $e', Colors.redAccent);
    } finally {
      _isActionBusy = false;
    }
  }

  void _showToast(String message, Color color) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
        ),
        backgroundColor: color.withOpacity(0.9),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Full Screen Preview (Behind Notch)
          Positioned.fill(
            child: _textureId != null
                ? FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: 1280,
                      height: 720,
                      child: Texture(textureId: _textureId!),
                    ),
                  )
                : Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: [Colors.grey.shade900, Colors.black],
                        radius: 1.2,
                      ),
                    ),
                    child: Center(
                      child: Icon(Icons.camera_rounded, size: 100, color: Colors.white.withOpacity(0.05)),
                    ),
                  ),
          ),

          // 2. High-Performance Frame Overlay
          if (_textureId != null && _isProcessingFrames)
            const Positioned.fill(child: _FrameOverlay()),

          // 3. Status Bar & Informative Header (SAFE AREA)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: _HeaderSection(status: _status, device: _currentDevice),
              ),
            ),
          ),

          // 4. Bottom Controls Area (SAFE AREA)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_errorMessage != null) _ErrorCard(message: _errorMessage!),
                    const SizedBox(height: 10),
                    _ControlPanel(
                      status: _status,
                      isProcessing: _isProcessingFrames,
                      onToggleCamera: _toggleCamera,
                      onToggleProcessing: (val) async {
                        if (_textureId == null) return;
                        await NitroCamera.instance.enableFrameProcessing(_textureId!, val ? 1 : 0);
                        setState(() => _isProcessingFrames = val);
                      },
                      devices: _devices,
                      selectedDevice: _currentDevice,
                      onDeviceChanged: (d) {
                        if (_status == CameraStatus.running) return;
                        setState(() => _currentDevice = d);
                      },
                      onTakePhoto: _takePhoto,
                      onToggleRecording: _toggleRecording,
                      isRecording: _isRecording,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderSection extends StatelessWidget {
  final CameraStatus status;
  final CameraDevice? device;

  const _HeaderSection({required this.status, this.device});

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (status) {
      CameraStatus.running => Colors.greenAccent,
      CameraStatus.opening || CameraStatus.closing => Colors.amberAccent,
      CameraStatus.error => Colors.redAccent,
      _ => Colors.white24,
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'NITRO CAM PRO',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.5,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _StatusPulse(color: statusColor),
                      const SizedBox(width: 8),
                      Text(
                        status.name.toUpperCase(),
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (device != null) ...[
                const Spacer(),
                _InfoChip(label: 'ID: ${device!.id}'),
                const SizedBox(width: 6),
                _InfoChip(label: device!.position == 1 ? 'BACK' : 'FRONT', isHighlight: true),
              ]
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPulse extends StatefulWidget {
  final Color color;
  const _StatusPulse({required this.color});

  @override
  State<_StatusPulse> createState() => _StatusPulseState();
}

class _StatusPulseState extends State<_StatusPulse> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl.drive(CurveTween(curve: Curves.easeInOut)),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final bool isHighlight;
  const _InfoChip({required this.label, this.isHighlight = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isHighlight ? Colors.cyanAccent.withOpacity(0.15) : Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isHighlight ? Colors.cyanAccent.withOpacity(0.3) : Colors.transparent),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isHighlight ? Colors.cyanAccent : Colors.white70,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w500),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  final CameraStatus status;
  final bool isProcessing;
  final VoidCallback onToggleCamera;
  final ValueChanged<bool> onToggleProcessing;
  final List<CameraDevice> devices;
  final CameraDevice? selectedDevice;
  final ValueChanged<CameraDevice?> onDeviceChanged;
  final VoidCallback onTakePhoto;
  final VoidCallback onToggleRecording;
  final bool isRecording;

  const _ControlPanel({
    required this.status,
    required this.isProcessing,
    required this.onToggleCamera,
    required this.onToggleProcessing,
    required this.devices,
    required this.selectedDevice,
    required this.onDeviceChanged,
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
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(35),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Device Selector
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DEVICE', style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                      const SizedBox(height: 2),
                      DropdownButton<CameraDevice>(
                        value: selectedDevice,
                        dropdownColor: Colors.grey.shade900,
                        underline: const SizedBox(),
                        icon: const Icon(Icons.arrow_drop_down_circle_outlined, color: Colors.cyanAccent, size: 18),
                        onChanged: isRunning || isChanging ? null : onDeviceChanged,
                        items: devices.map((d) => DropdownMenuItem(
                          value: d,
                          child: Text(d.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                        )).toList(),
                      ),
                    ],
                  ),
                  if (isRunning) ...[
                    _ControlCircleButton(
                      onTap: onTakePhoto,
                      icon: Icons.camera_rounded,
                      color: Colors.white,
                    ),
                    _ControlCircleButton(
                      onTap: onToggleRecording,
                      icon: isRecording ? Icons.stop_rounded : Icons.videocam_rounded,
                      color: isRecording ? Colors.redAccent : Colors.white,
                      isPulse: isRecording,
                    ),
                  ],
                  // Stream Toggle
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('STREAM', style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                      Switch(
                        value: isProcessing,
                        onChanged: isRunning ? onToggleProcessing : null,
                        activeColor: Colors.cyanAccent,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 25),
              // Main Launch Button
              GestureDetector(
                onTap: isChanging ? null : onToggleCamera,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: double.infinity,
                  height: 65,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: (isRunning ? Colors.redAccent : Colors.cyanAccent).withOpacity(0.2),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      )
                    ],
                    gradient: LinearGradient(
                      colors: isRunning
                          ? [Colors.redAccent, Colors.red.shade900]
                          : [Colors.cyanAccent, Colors.blue.shade900],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Center(
                    child: isChanging
                        ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(isRunning ? Icons.power_settings_new_rounded : Icons.camera_enhance_rounded, color: Colors.white, size: 26),
                              const SizedBox(width: 12),
                              Text(
                                isRunning ? 'SHUTDOWN' : 'ACTIVATE CAMERA',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.5,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
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
          color: color.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
    );
  }
}

class _FrameOverlay extends StatefulWidget {
  const _FrameOverlay();

  @override
  State<_FrameOverlay> createState() => _FrameOverlayState();
}

class _FrameOverlayState extends State<_FrameOverlay> {
  ui.Image? _image;
  final _fpsCounter = ValueNotifier<double>(0);
  final List<DateTime> _frames = [];
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = NitroCamera.instance.frameStream.listen((frame) {
      final now = DateTime.now();
      _frames.add(now);
      _frames.removeWhere((t) => now.difference(t) > const Duration(seconds: 1));
      _fpsCounter.value = _frames.length.toDouble();

      ui.decodeImageFromPixels(
        frame.pixels,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        (image) {
          if (mounted) {
            setState(() {
              _image?.dispose();
              _image = image;
            });
          } else {
            image.dispose();
          }
        },
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _image?.dispose();
    _fpsCounter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (_image != null)
          Opacity(
            opacity: 0.6,
            child: RawImage(image: _image, fit: BoxFit.cover),
          ),
        Positioned(
          top: 130, // Positioned below header
          left: 20,
          child: ValueListenableBuilder<double>(
            valueListenable: _fpsCounter,
            builder: (context, fps, _) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withOpacity(0.85),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.speed_rounded, color: Colors.black, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'STREAMING: ${fps.toInt()} FPS',
                    style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.black, fontSize: 11, letterSpacing: 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
