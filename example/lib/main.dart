import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:path_provider/path_provider.dart';
import 'camera_preview_widget.dart';
import 'widgets/control_panel.dart';
import 'widgets/camera_header.dart';
import 'widgets/frame_overlay.dart';
import 'widgets/filter_selector.dart';
import 'widgets/camera_status_widgets.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: CameraApp(),
  ));
}

class CameraApp extends StatefulWidget {
  const CameraApp({super.key});

  @override
  State<CameraApp> createState() => _CameraAppState();
}

class _CameraAppState extends State<CameraApp> with WidgetsBindingObserver {
  // Logic State
  List<CameraDevice> _devices = [];
  CameraDevice? _currentDevice;
  bool _loading = true;
  String? _errorMessage;

  // Camera Settings
  CameraStatus _status = CameraStatus.closed;
  bool _isRecording = false;
  int? _activeTextureId;
  int _width = 1280;
  int _height = 720;
  int _fps = 60;

  // Custom Filter State
  String _currentFilterName = 'NORMAL';
  final Map<String, String> _filters = {
    'NORMAL': '',
    'INVERT': 'void main() { fragColor = vec4(1.0 - inputColor.rgb, inputColor.a); }',
    'GRAYSCALE': 'void main() { float luma = dot(inputColor.rgb, vec3(0.299, 0.587, 0.114)); fragColor = vec4(vec3(luma), inputColor.a); }',
    'SEPIA': 'void main() { vec3 res = vec3(dot(inputColor.rgb, vec3(0.393, 0.769, 0.189)), dot(inputColor.rgb, vec3(0.349, 0.686, 0.168)), dot(inputColor.rgb, vec3(0.272, 0.534, 0.131))); fragColor = vec4(res, inputColor.a); }',
    'VIGNETTE': 'void main() { float d = distance(uv, vec2(0.5)); float v = smoothstep(0.8, 0.3, d); fragColor = vec4(inputColor.rgb * v, inputColor.a); }',
  };

  bool _isProcessingFrames = false;
  int _samplingRate = 1;
  int _pixelFormat = 1; // 1 = BGRA
  int _cameraPermission = 0; // 0: unknown, 1: granted, 2: denied

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      setState(() => _status = CameraStatus.closed);
    } else if (state == AppLifecycleState.resumed) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      _cameraPermission = await NitroCamera.instance.getCameraPermissionStatus();
      if (_cameraPermission == 1) {
        final count = await NitroCamera.instance.getDeviceCount();
        final devices = <CameraDevice>[];
        for (var i = 0; i < count; i++) {
          devices.add(await NitroCamera.instance.getDevice(i));
        }
        devices.sort((a, b) => a.position.compareTo(b.position));
        if (mounted) {
          setState(() {
            _devices = devices;
            if (devices.isNotEmpty) {
              _currentDevice = devices.firstWhere(
                (d) => d.position == 1, // Prefer Back
                orElse: () => devices.first,
              );
              _status = CameraStatus.opening; // TRIGGERS THE PREVIEW
            }
          });
        }
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    }
  }

  Future<void> _grantPermission() async {
    final status = await NitroCamera.instance.requestCameraPermission();
    setState(() => _cameraPermission = status);
    if (status == 1) _init();
  }

  Future<void> _setFilter(String name) async {
    final tid = _activeTextureId;
    if (tid == null) return;
    final shader = _filters[name];
    if (shader == null) return;
    await NitroCamera.instance.setFilterShader(tid, shader);
    if (mounted) setState(() => _currentFilterName = name);
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraPermission != 1) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: PermissionGuard(cameraStatus: _cameraPermission, onGrant: _grantPermission),
      );
    }

    if (_loading) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.cyanAccent)));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Automated Camera Preview
          Positioned.fill(
            child: _currentDevice != null && _status != CameraStatus.closed
                ? NitraCameraPreview(
                    device: _currentDevice!,
                    width: _width,
                    height: _height,
                    fps: _fps,
                    filterShader: _filters[_currentFilterName],
                    onStarted: (tid) => setState(() {
                      _status = CameraStatus.running;
                      _activeTextureId = tid;
                    }),
                    onError: (err) => setState(() => _errorMessage = err),
                  )
                : const Center(child: Text("SELECT A CAMERA DEVICE", style: TextStyle(color: Colors.white24))),
          ),

          // 2. Automated YUV Processing Visualization
          FrameOverlay(isProcessing: _isProcessingFrames),

          // 3. Floating UI Content
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),
                CameraHeader(status: _status, currentDevice: _currentDevice, width: _width, height: _height, fps: _fps),
                const Spacer(),
                if (_errorMessage != null) ErrorCard(message: _errorMessage!),
                FilterSelector(
                  filters: _filters,
                  currentFilterName: _currentFilterName,
                  onFilterSelected: _setFilter,
                ),
                ControlPanel(
                  status: _status,
                  isProcessing: _isProcessingFrames,
                  devices: _devices,
                  selectedDevice: _currentDevice,
                  selectedWidth: _width,
                  selectedFps: _fps,
                  isRecording: _isRecording,
                  onSelectDevice: (d) => setState(() { _currentDevice = d; _status = CameraStatus.opening; }),
                  onResolutionChanged: (w, h) => setState(() { _width = w; _height = h; }),
                  onFpsChanged: (f) => setState(() => _fps = f),
                  onToggleProcessing: (val) async {
                    final tid = _activeTextureId;
                    if (tid == null) return;
                    await NitroCamera.instance.enableFrameProcessing(tid, val ? 1 : 0);
                    setState(() => _isProcessingFrames = val);
                  },
                  onTakePhoto: () async {
                    final tid = _activeTextureId;
                    if (tid == null) return;
                    final result = await NitroCamera.instance.takePhoto(tid);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("SAVED: ${result.path}"), backgroundColor: Colors.cyanAccent.withValues(alpha: 0.8)));
                  },
                   onToggleRecording: () async {
                    final tid = _activeTextureId;
                    if (tid == null) return;
                    if (_isRecording) {
                      final result = await NitroCamera.instance.stopVideoRecording(tid);
                      setState(() => _isRecording = false);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("VIDEO SAVED: ${result.path} (${(result.fileSize / 1024 / 1024).toStringAsFixed(1)} MB)")));
                    } else {
                      final tempDir = await getTemporaryDirectory();
                      final path = "${tempDir.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4";
                      await NitroCamera.instance.startVideoRecording(tid, path);
                      setState(() => _isRecording = true);
                    }
                  },
                  samplingRate: _samplingRate,
                  pixelFormat: _pixelFormat,
                  onSamplingRateChanged: (val) async {
                    final tid = _activeTextureId;
                    if (tid != null) {
                      await NitroCamera.instance.setSamplingRate(tid, val);
                    }
                    setState(() => _samplingRate = val);
                  },
                  onPixelFormatChanged: (val) async {
                    final tid = _activeTextureId;
                    if (tid != null) {
                      await NitroCamera.instance.setFrameFormat(tid, val);
                    }
                    setState(() => _pixelFormat = val);
                  },
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
