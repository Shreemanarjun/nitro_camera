import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:path_provider/path_provider.dart';

enum CameraStatus { closed, opening, closing, running, error }

class CameraState {
  static final devices = signal<List<CameraDevice>>([]);
  static final currentDevice = signal<CameraDevice?>(null);
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
  static final isLastCapturedVideo = ValueNotifier<bool>(false);
  static final isCapturing = ValueNotifier<bool>(false);

  static final currentFilterName = signal('NORMAL');

  static const Map<String, String> filters = {
    'NORMAL': '',
    'INVERT':
        'void main() { fragColor = vec4(1.0 - inputColor.rgb, inputColor.a); }',
    'GRAYSCALE':
        'void main() { float luma = dot(inputColor.rgb, vec3(0.299, 0.587, 0.114)); fragColor = vec4(vec3(luma), inputColor.a); }',
    'SEPIA':
        'void main() { vec3 res = vec3(dot(inputColor.rgb, vec3(0.393, 0.769, 0.189)), dot(inputColor.rgb, vec3(0.349, 0.686, 0.168)), dot(inputColor.rgb, vec3(0.272, 0.534, 0.131))); fragColor = vec4(res, inputColor.a); }',
    'VIGNETTE':
        'void main() { float d = distance(uv, vec2(0.5)); float v = smoothstep(0.8, 0.3, d); fragColor = vec4(inputColor.rgb * v, inputColor.a); }',
  };

  static final isProcessingFrames = signal(false);
  static final samplingRate = signal(1);
  static final pixelFormat = signal(1); // 1 = BGRA
  static final cameraPermission = signal(
    0,
  ); // 0: unknown, 1: granted, 2: denied
  static final photoTrigger = signal(0); // Inc to trigger flash
  static final controlMode = signal('FILTERS'); // FILTERS or SETTINGS
  static final selectedAspectRatio = signal<double?>(null);
  static final showFilters = signal(false);

  // Add Initialization logic
  static Future<void> init() async {
    try {
      if (loading.value && devices.value.isNotEmpty) return;
      loading.value = true;

      final perm = await NitroCamera.instance.getCameraPermissionStatus();
      cameraPermission.value = perm;

      if (perm == 1) {
        final loaded = await NitroCamera.instance.getAvailableCameraDevices();
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
    cameraPermission.value = status;
    if (status == 1) await init();
  }

  static Future<void> selectDevice(CameraDevice d) async {
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
      await NitroCamera.instance.enableFrameProcessing(
        activeTextureId.value!,
        (m == 'SCANNER') ? 1 : 0,
      );
    }
  }

  static Future<void> toggleProcessing(bool val) async {
    if (activeTextureId.value != null) {
      await NitroCamera.instance.enableFrameProcessing(
        activeTextureId.value!,
        val ? 1 : 0,
      );
    }
    isProcessingFrames.value = val;
  }

  static Future<void> setResolution(int w, int h) async {
    width.value = w;
    height.value = h;
  }

  static Future<void> setFps(int f) async {
    fps.value = f;
  }

  static Future<void> setPixelFormat(int format) async {
    if (activeTextureId.value != null) {
      await NitroCamera.instance.setFrameFormat(activeTextureId.value!, format);
    }
    pixelFormat.value = format;
  }

  static Future<void> setSamplingRate(int rate) async {
    if (activeTextureId.value != null) {
      await NitroCamera.instance.setSamplingRate(activeTextureId.value!, rate);
    }
    samplingRate.value = rate;
  }

  static Future<void> setFlash(FlashMode m) async {
    flashMode.value = m;
    final tid = activeTextureId.value;
    if (tid != null) {
      await NitroCamera.instance.setFlash(tid, m.index);
    }
  }

  static Future<void> setZoom(double z) async {
    final dev = currentDevice.value;
    if (dev == null) return;

    final clamped = z.clamp(dev.minZoom, dev.maxZoom);
    currentZoom.value = clamped;

    final tid = activeTextureId.value;
    if (tid == null) return;

    // Fast zoom: Send to native immediately for smooth experience
    await NitroCamera.instance.setZoom(tid, clamped);
  }

  static Future<void> setFocusPoint(double x, double y) async {
    final tid = activeTextureId.value;
    if (tid != null) {
      await NitroCamera.instance.setFocusPoint(tid, x, y);
    }
  }

  static Future<void> setFilter(String name) async {
    currentFilterName.value = name;
    final tid = activeTextureId.value;
    if (tid != null) {
      final source = filters[name] ?? '';
      await NitroCamera.instance.setFilterShader(tid, source);
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

      final result = await NitroCamera.instance
          .takePhoto(tid)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException("Hardware capture timeout"),
          );

      lastCapturedPath.value = result.path;
      isLastCapturedVideo.value = false;
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
        isRecording.value = false;
        lastCapturedPath.value = result.path;
        isLastCapturedVideo.value = true;
      } catch (e) {
        isRecording.value = false;
        debugPrint("Stop video failed: $e");
      }
    } else {
      try {
        final tempDir = await getTemporaryDirectory();
        final path =
            "${tempDir.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4";
        await NitroCamera.instance.startVideoRecording(tid, path);
        isRecording.value = true;
      } catch (e) {
        debugPrint("Start video failed: $e");
      }
    }
  }

  static Future<void> toggleCamera() async {
    if (devices.value.length < 2) return;
    final currentIndex = devices.value.indexWhere(
      (d) => d.id == currentDevice.value?.id,
    );
    final nextIndex = (currentIndex + 1) % devices.value.length;
    selectDevice(devices.value[nextIndex]);
  }
}
