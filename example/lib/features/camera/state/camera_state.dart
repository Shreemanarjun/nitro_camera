import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:path_provider/path_provider.dart';

enum CameraStatus { closed, opening, closing, running, error }

class CameraState {
  static final devices = signal<List<CameraDeviceInfo>>([]);
  static final currentDevice = signal<CameraDeviceInfo?>(null);
  static final loading = signal(true);
  static final errorMessage = signal<String?>(null);

  static final status = signal<CameraStatus>(CameraStatus.closed);
  static final isRecording = signal(false);
  static final activeTextureId = signal<int?>(null);
  static final flashMode = signal(FlashMode.off);
  static final currentZoom = signal(1.0);
  static final focusIndicatorTrigger = signal<Offset?>(null);

  static final width = signal(1920);
  static final height = signal(1080);
  static final fps = signal(60);

  static final mode = signal('PHOTO'); // PHOTO, VIDEO, SCANNER
  static final lastCapturedPath = signal<String?>(null);
  static final isLastCapturedVideo = signal<bool>(false);
  static final isCapturing = signal<bool>(false);
  static final recordingDuration = signal<int>(0); // in seconds
  static Timer? _recordingTimer;

  static final currentFilterName = signal('NORMAL');

  static const Map<String, String> filters = {
    'NORMAL': '',
    'INVERT':
        'void main() { vec4 c = inputColor; fragColor = vec4(1.0 - c.rgb, c.a); }',
    'GRAYSCALE':
        'void main() { vec4 c = inputColor; float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114)); fragColor = vec4(vec3(luma), c.a); }',
    'SEPIA':
        'void main() { vec4 c = inputColor; vec3 res = vec3(dot(c.rgb, vec3(0.393, 0.769, 0.189)), dot(c.rgb, vec3(0.349, 0.686, 0.168)), dot(c.rgb, vec3(0.272, 0.534, 0.131))); fragColor = vec4(res, c.a); }',
    'VIGNETTE':
        'void main() { vec4 c = inputColor; float d = distance(uv, vec2(0.5)); float v = smoothstep(0.8, 0.3, d); fragColor = vec4(c.rgb * v, c.a); }',
    'CYBERPUNK':
        'void main() { vec4 c = inputColor; float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114)); vec3 pink = vec3(1.0, 0.0, 1.0); vec3 blue = vec3(0.0, 1.0, 1.0); fragColor = vec4(mix(blue, pink, luma), c.a); }',
  };

  static final isProcessingFrames = signal(false);
  static final samplingRate = signal(1);
  static final pixelFormat = signal(1); // 1 = BGRA
  // 0: unknown, 1: granted, 2: denied
  static final cameraPermission = signal(0);
  static final photoTrigger = signal(0); // Inc to trigger flash
  static final controlMode = signal('FILTERS'); // FILTERS or SETTINGS
  static final selectedAspectRatio = signal<double?>(null);
  static final showFilters = signal(false);

  static final previewMode = signal<PreviewMode>(PreviewMode.texture);

  static Future<void> setPreviewMode(PreviewMode m) async {
    previewMode.value = m;
    // Reset shader to current filter to clear any transient 'SCANLINE' from native memory
    final tid = activeTextureId.value;
    if (tid != null) {
      final source = filters[currentFilterName.value] ?? '';
      NitroCamera.instance.setFilterShader(tid, source);
    }
  }

  // New: List of all captured media items
  static final capturedMedia = signal<List<({String path, bool isVideo})>>([]);

  // Add Initialization logic
  static Future<void> init() async {
    // Explicitly yield to event loop so we don't block the UI thread during hardware query
    await Future.microtask(() {});

    try {
      if (loading.value && devices.value.isNotEmpty) return;
      loading.value = true;

      final perm = NitroCamera.instance.getCameraPermissionStatus();
      cameraPermission.value = perm;

      if (perm == 1) {
        final loaded = await CameraController.getAvailableCameraDevices();
        devices.value = List.from(loaded);

        // 2. Early warming: Pick the primary back camera (usually first tele/wide)
        final backCam =
            loaded.where((d) => d.position == 1).firstOrNull ??
            loaded.firstOrNull;
        if (backCam != null && currentDevice.value == null) {
          await selectDevice(backCam);
        }
      }
      loading.value = false;
    } catch (e) {
      loading.value = false;
      errorMessage.value = e.toString();
    }
  }

  static Future<void> grantPermission() async {
    final status = await NitroCamera.instance.requestCameraPermission();
    await NitroCamera.instance
        .requestMicrophonePermission(); // Ensure audio for video
    cameraPermission.value = status;
    if (status == 1) init();
  }

  static Future<void> selectDevice(CameraDeviceInfo d) async {
    if (currentDevice.value?.id == d.id) return;
    currentDevice.value = d;
    currentZoom.value = d.neutralZoom; // Reset zoom to neutral for the lens
    status.value = CameraStatus.opening;
  }

  static Future<void> setMode(String m) async {
    if (mode.value == m) return;
    mode.value = m;
    isProcessingFrames.value = (m == 'SCANNER');

    if (activeTextureId.value != null) {
      NitroCamera.instance.enableFrameProcessing(
        activeTextureId.value!,
        (m == 'SCANNER') ? 1 : 0,
      );
    }
  }

  static void toggleProcessing(bool val) {
    if (activeTextureId.value != null) {
      NitroCamera.instance.enableFrameProcessing(
        activeTextureId.value!,
        val ? 1 : 0,
      );
    }
    isProcessingFrames.value = val;
  }

  static void setResolution(int w, int h) {
    // Only update if change is significant to avoid redundant restarts
    if ((width.value - w).abs() < 10 && (height.value - h).abs() < 10) return;
    width.value = w;
    height.value = h;
  }

  static void setFps(int f) {
    fps.value = f;
  }

  static void setPixelFormat(int format) {
    if (activeTextureId.value != null) {
      NitroCamera.instance.setFrameFormat(activeTextureId.value!, format);
    }
    pixelFormat.value = format;
  }

  static void setSamplingRate(int rate) {
    if (activeTextureId.value != null) {
      NitroCamera.instance.setSamplingRate(activeTextureId.value!, rate);
    }
    samplingRate.value = rate;
  }

  static void setFlash(FlashMode m) {
    flashMode.value = m;
    final tid = activeTextureId.value;
    if (tid != null) {
      NitroCamera.instance.setFlash(tid, m.index);
    }
  }

  static void setZoom(double z) {
    final dev = currentDevice.value;
    if (dev == null) return;
    final clamped = z.clamp(dev.minZoom, dev.maxZoom);
    currentZoom.value = clamped;
    final tid = activeTextureId.value;
    if (tid == null) return;
    NitroCamera.instance.setZoom(tid, clamped);
  }

  static void setFocusPoint(double x, double y) {
    final tid = activeTextureId.value;
    if (tid != null) {
      NitroCamera.instance.setFocusPoint(tid, x, y);
    }
  }

  static void setFilter(String name) {
    currentFilterName.value = name;
    final tid = activeTextureId.value;
    if (tid != null) {
      final source = filters[name] ?? '';
      NitroCamera.instance.setFilterShader(tid, source);
    }
  }

  static Future<void> takePhoto() async {
    if (isCapturing.value) return;

    final tid = activeTextureId.value;
    if (tid == null) return;

    try {
      isCapturing.value = true;
      photoTrigger.value++;
      HapticFeedback.mediumImpact();

      final result = await NitroCamera.instance.takePhoto(tid);

      batch(() {
        lastCapturedPath.value = result.path;
        isLastCapturedVideo.value = false;

        // Add to gallery
        capturedMedia.value = [
          ...capturedMedia.value,
          (path: result.path, isVideo: false),
        ];
      });

      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint("Photo failed: $e");
    } finally {
      isCapturing.value = false;
    }
  }

  static Future<void> toggleRecording() async {
    final tid = activeTextureId.value;
    if (tid == null) return;

    if (isRecording.value) {
      try {
        final result = await NitroCamera.instance.stopVideoRecording(tid);
        _recordingTimer?.cancel();
        _recordingTimer = null;

        batch(() {
          isRecording.value = false;
          recordingDuration.value = 0;
          lastCapturedPath.value = result.path;
          isLastCapturedVideo.value = true;

          // Add to gallery
          capturedMedia.value = [
            ...capturedMedia.value,
            (path: result.path, isVideo: true),
          ];
        });
      } catch (e) {
        isRecording.value = false;
        _recordingTimer?.cancel();
        _recordingTimer = null;
        debugPrint("Stop video failed: $e");
      }
    } else {
      try {
        final tempDir = await getTemporaryDirectory();
        final path =
            "${tempDir.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4";
        await NitroCamera.instance.startVideoRecording(tid, path);

        isRecording.value = true;
        recordingDuration.value = 0;
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          recordingDuration.value++;
        });
      } catch (e) {
        debugPrint("Start video failed: $e");
      }
    }
  }

  static void toggleCamera() {
    if (devices.value.length < 2) return;
    final currentIndex = devices.value.indexWhere(
      (d) => d.id == currentDevice.value?.id,
    );
    final nextIndex = (currentIndex + 1) % devices.value.length;
    selectDevice(devices.value[nextIndex]);
  }
}
