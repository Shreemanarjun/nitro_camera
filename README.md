# Nitro Camera 🚀

A high-performance, [vision-camera](https://github.com/mrousavy/react-native-vision-camera)-style camera plugin for Flutter, built on the **Nitro** FFI bridge — type-safe, zero-copy native bindings with **zero method-channel overhead**.

[![Nitro](https://img.shields.io/badge/Powered%20by-Nitro-cyan.svg)](https://github.com/mrousavy/nitro)
[![Flutter](https://img.shields.io/badge/Flutter-3.0+-blue.svg)](https://flutter.dev)

## ⚡ Why Nitro?

| Feature | Method Channel | FFI (manual) | **Nitro** |
| :--- | :---: | :---: | :---: |
| **Overhead per call** | ~0.3 ms | ~0 ms | **~0 ms** |
| **Type safety** | stringly-typed | manual | **generated, strict** |
| **Async support** | ✅ | manual isolates | **✅ generated** |
| **Streams** | ✅ slow | manual SendPort | **✅ zero-copy** |
| **Zero-copy buffers** | ❌ | manual | **✅ @HybridStruct** |

## 🌟 Features

* **Declarative + imperative** — a declarative `CameraView` widget *and* a `CameraController` for imperative control, mirroring vision-camera.
* **Device discovery** — enumerate physical/logical cameras with their formats, zoom range, exposure range, and hardware level; pick with vision-camera-style ranking.
* **Photo & video capture** — `takePhoto`, `takeSnapshot`, and `startRecording` / `stopRecording` with codec, bitrate, size/duration limits, and GPS geotagging.
* **Live controls** — zoom, focus/tap-to-focus, exposure, flash/torch, white balance, HDR, low-light boost, and video stabilization applied as cheap live updates (no session reopen).
* **Code scanning** — QR, 1D/2D barcodes, GS1, postal, and Pharmacode symbologies decoded on a background isolate with zero-copy frame hand-off.
* **Frame processing** — stream raw `YUV_420_888` / `BGRA_8888` frames into a worker isolate with drop-latest backpressure.
* **Native ML detectors** — optional ML Kit barcode/face detection with typed results.
* **GPU filters** — apply a GLSL fragment shader to the pipeline (Android native GL; iOS Core Image for capture/recording).

## 🚀 Installation

### 1. Add the dependency

```yaml
dependencies:
  nitro_camera: ^0.1.0
```

Or from the terminal:

```bash
flutter pub add nitro_camera
```

### 2. iOS setup

Requires **iOS 13.0+**. Add usage descriptions to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>We need the camera to show the preview and capture photos/videos.</string>
<key>NSMicrophoneUsageDescription</key>
<string>We need the microphone to record video with audio.</string>
<!-- Only if you save to the photo library: -->
<key>NSPhotoLibraryAddUsageDescription</key>
<string>We save captured photos and videos to your library.</string>
```

### 3. Android setup

The `CAMERA` and `RECORD_AUDIO` permissions are declared by the plugin manifest
and merged automatically. Request them at runtime before opening the camera
(see below). Minimum `minSdkVersion 24`.

## ⏱️ Quick Start

```dart
import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    // 1. Permission
    await CameraController.requestCameraPermission();

    // 2. Discover devices and pick the back camera
    final devices = await CameraController.getAvailableCameraDevices();
    final back = devices.backCamera() ?? devices.first;

    // 3. Create + initialize the controller
    final controller = CameraController(device: back, audio: true);
    await controller.initialize(fps: 30);

    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null || !c.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Positioned.fill(child: CameraPreview(controller: c)),
        Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Center(
            child: FloatingActionButton(
              onPressed: () async {
                final photo = await c.takePhoto();
                debugPrint('Saved to ${photo.path}');
              },
              child: const Icon(Icons.camera),
            ),
          ),
        ),
      ],
    );
  }
}
```

## 🧭 API Reference

### Device discovery & selection

```dart
// All cameras, each with formats, zoom/exposure ranges, hardware level, etc.
final List<CameraDeviceInfo> devices =
    await CameraController.getAvailableCameraDevices();

// vision-camera-style selection helpers (extension on List<CameraDeviceInfo>):
final back  = devices.backCamera();     // best back camera
final front = devices.frontCamera();    // best front camera
final usb   = devices.externalCamera(); // external/USB camera, if any

// Or rank explicitly (prefers full hardware level + wide-angle lens):
final device = selectCameraDevice(
  devices,
  position: CameraPosition.back,
  physicalDevices: [PhysicalDeviceType.wideAngleCamera],
);
```

`CameraDeviceInfo` exposes: `id`, `name`, `position`, `lensType`, `sensorOrientation`,
`minZoom`/`maxZoom`/`neutralZoom`, `hasFlash`/`hasTorch`, `maxPhotoWidth`/`maxPhotoHeight`,
`minExposure`/`maxExposure`, `minFocusDistanceCm`, `isMultiCam`, `supportsLowLightBoost`,
`supportsRawCapture`, `supportsFocus`, `hardwareLevel`, `physicalDevices`, `formats`.

### Permissions

```dart
final PermissionStatus cam = await CameraController.requestCameraPermission();
final PermissionStatus mic = await CameraController.requestMicrophonePermission();
// PermissionStatus: notDetermined | granted | denied | restricted
```

### Rendering the preview

Two rendering widgets are provided:

| Widget | Use it when |
| :--- | :--- |
| **`CameraPreview`** | You manage the `CameraController` yourself (imperative). |
| **`CameraView`** | You want the widget to own the session lifecycle (declarative). |

```dart
// Imperative — you own the controller:
CameraPreview(
  controller: controller,
  mode: PreviewMode.texture,        // texture | platformView | impeller
  resizeMode: PreviewResizeMode.cover, // cover (crop) | contain (letterbox)
  child: myOverlay,                 // optional overlay on top of the preview
)
```

```dart
// Declarative — the widget opens/closes the session and hands you the controller:
CameraView(
  device: device,
  fps: 60,
  audio: true,
  isActive: true,                   // toggle to pause/resume streaming
  resizeMode: PreviewResizeMode.cover,
  onInitialized: (c) => controller = c, // drive controls/capture imperatively
  onError: (e) => print(e),
  child: myOverlay,
)
```

> **`PreviewMode.platformView` is Android-only** (native hardware overlay). On
> iOS it falls back to `texture`.

### Controller lifecycle

```dart
final controller = CameraController(device: device, audio: true);
await controller.initialize(width: w, height: h, fps: 30);

controller.isInitialized;   // true once a texture exists
controller.textureId;       // Flutter texture id
controller.width / .height; // negotiated resolution
controller.resolvedConfig;  // what format negotiation actually selected

controller.pausePreview();  // stop streaming (keeps the session)
controller.resumePreview();
await controller.closeSession(); // free the camera HW, keep the texture frame
await controller.dispose();      // tear everything down
```

`CameraController` is a `ChangeNotifier` — wrap UI in an `AnimatedBuilder`/`ListenableBuilder`
to rebuild when state (zoom, flash, recording…) changes.

### Live controls

```dart
controller.setZoom(2.0);                 // clamped to device.min/maxZoom
controller.focus(0.5, 0.5);              // tap-to-focus, normalized 0..1
controller.setAutoFocus(AutoFocusMode.continuous); // off | continuous | locked
controller.setExposure(0.0);             // device.min/maxExposure
controller.setFlash(FlashMode.auto);     // off | on | auto
```

All controls apply as diff-driven live updates — no session reopen — the same
model as vision-camera's declarative `configure()`.

### Declarative configuration

Instead of calling individual setters you can hold one immutable
`CameraConfiguration` and apply diffs:

```dart
await controller.configure(
  controller.configuration!.copyWith(
    zoom: 2.0,
    flash: FlashMode.on,
    torch: true,
    whiteBalanceKelvin: 5600,      // 0 = auto
    videoHdr: true,
    lowLightBoost: true,
    videoStabilization: VideoStabilizationMode.cinematic,
    filterShader: myGlsl,
  ),
);
```

A change to `deviceId` / `format` / `fps` / `enableAudio` reopens the session
(the `textureId` changes); everything else is a cheap live update.

### Photo capture

```dart
// Full-quality still:
final PhotoResult photo = await controller.takePhoto();

// With per-shot options:
final photo2 = await controller.takePhotoWithOptions(const PhotoCaptureOptions(
  flash: FlashMode.auto,
  quality: QualityPrioritization.quality, // speed | balanced | quality
  enableShutterSound: true,
  skipMetadata: false,
  enableAutoRedEyeReduction: true,
));

// Fast preview-frame grab (no full capture pipeline):
final snap = await controller.takeSnapshot();

// PhotoResult: path, width, height, fileSize, orientation, isMirrored, timestamp
```

### Video recording

```dart
await controller.startRecording(
  '/path/to/output.mp4',
  options: const RecordingOptions(
    codec: 0,             // VideoCodec.h264 (0) | .hevc (1)
    fileType: 0,          // VideoFileType.mp4 (0) | .mov (1)
    bitRate: 0,           // 0 = encoder default
    maxDurationMs: 0,     // 0 = unlimited
    maxFileSizeBytes: 0,  // 0 = unlimited
  ),
);

controller.pauseRecording();
controller.resumeRecording();

final RecordingResult result = await controller.stopRecording();
// result: path, durationMs, fileSize, width, height, codec, fileType, finishedReason

controller.cancelRecording(); // discard without finalizing
controller.isRecording;       // current state
```

### Code scanning

```dart
// The scanner decodes the YUV luma plane, so stream YUV + turn on frames:
await controller.configure(controller.configuration!.copyWith(
  pixelFormat: PixelFormat.yuv420,
  enableFrameProcessing: true,
));

final scanner = CodeScanner(
  kind: CodeScanKind.qr,          // qr | oneD | twoD | postal | pharma | all
  mode: ScanMode.continuous,      // continuous | oneShot
  confirmationFrames: 2,          // same payload on N frames before confirming
  cooldown: const Duration(milliseconds: 1500),
);

await scanner.start(controller.frameStream);

scanner.results.listen((CodeResult code) {
  print('${code.format}: ${code.text}');  // confirmed, deduplicated
});
scanner.detections.listen((code) { /* raw per-frame — drive live highlights */ });
scanner.stats.listen((s) => print('decode ${s.elapsedMillis}ms'));

// oneShot: after a hit, call scanner.resume() to scan again.
await scanner.dispose();
```

> BGRA bytes decode as noise — the scanner requires `PixelFormat.yuv420`.

`CodeResult` carries `text`, `format`, `timestamp`, `isGs1`, `windowPoints`
(symbol corner points normalized to the on-screen viewfinder, ready to paint
over the preview), and `isbn` (for Bookland EAN-13).

### Frame processing (custom analysis)

Run your own per-frame handler on a background isolate:

```dart
// Handler MUST be top-level or static (it runs on a worker isolate):
int meanLuma(FrameData frame) {
  var sum = 0;
  for (var i = 0; i < frame.bytes.length; i += 64) sum += frame.bytes[i];
  return sum ~/ (frame.bytes.length ~/ 64);
}

final processor = CameraFrameProcessor<int>(meanLuma);
await processor.start();

controller.enableFrameProcessing();          // required for frameStream to emit
processor.attach(controller.frameStream);    // moves pixels to the worker isolate
processor.results.listen((luma) => print('brightness $luma'));
```

`FrameData` exposes `bytes` (a copy owned by the worker), `width`, `height`,
`format` (0 = YUV luma plane, 1 = BGRA), `bytesPerRow` (walk rows by
`effectiveBytesPerRow`, not by `width`), and `isMirrored`.

### Native ML detectors (ML Kit)

```dart
controller.startDetector(NativeDetector.barcode); // or .face
controller.detections.listen((DetectionResult r) {
  // typed barcode/face results with bounds
});
controller.stopDetector();
```

> Requires the host app to add the matching ML Kit dependency.

### GPU filters / shaders

```dart
controller.setFilterShader(glslFragmentSource); // '' clears the filter
```

* **Android** runs arbitrary GLSL in the native GL renderer (preview + recording).
* **iOS** maps the built-in filter set (invert, grayscale, sepia, vignette, …)
  to Core Image for photo capture and video recording; live-preview filtering
  is composited on the Flutter layer.

### Events & streams

```dart
controller.events.listen((CameraSessionEvent e) {
  // started / stopped / error / interruption for THIS session
});

CameraController.allEvents;          // events across all open sessions
controller.frameDropReasons;         // sustained drops = processor too slow
controller.thermalStates;            // device thermal state changes
controller.frameStream;              // raw CameraFrame stream (this session)
```

## 🎛️ Enum reference

| Enum | Values |
| :--- | :--- |
| `CameraPosition` | `front`, `back`, `external` |
| `CameraLensType` | `unknown`, `wideAngle`, `ultraWideAngle`, `telephoto` |
| `FlashMode` | `off`, `on`, `auto` |
| `AutoFocusMode` | `off`, `continuous`, `locked` |
| `VideoStabilizationMode` | `off`, `standard`, `cinematic`, `cinematicExtended`, `auto` |
| `QualityPrioritization` | `speed`, `balanced`, `quality` |
| `VideoCodec` | `h264`, `hevc` |
| `VideoFileType` | `mp4`, `mov` |
| `PixelFormat` | `yuv420` (0), `bgra` (1) |
| `PermissionStatus` | `notDetermined`, `granted`, `denied`, `restricted` |
| `CodeScanKind` | `qr`, `oneD`, `twoD`, `postal`, `pharma`, `all` |
| `ScanMode` | `continuous`, `oneShot` |
| `NativeDetector` | `barcode`, `face` |
| `PreviewMode` | `texture`, `platformView`, `impeller` |
| `PreviewResizeMode` | `cover`, `contain` |

## 📂 Project Structure

* `android/` — native Android implementation (`Camera2` + OpenGL renderer).
* `ios/` — native iOS implementation (`AVFoundation` + Core Image).
* `lib/` — strongly-typed Dart API:
  * `nitro_camera.native.dart` + `generated/` — the FFI/native boundary.
  * `models/` — data types (devices, formats, results, events).
  * `configuration/` — declarative config + format negotiation.
  * `controller/` — the `CameraController`.
  * `processing/` — isolate-based frame processing.
  * `scanner/` — code-scanning engine + decoders.
  * `widgets/` — `CameraView` + `CameraPreview`.
* `example/` — a full showcase app (glassmorphic UI, live vision diagnostics).

## 🏗️ Development & Bindings

This project uses the **Nitrogen** toolkit to generate the C++/Kotlin/Swift/Dart
glue. To regenerate after editing `lib/src/nitro_camera.native.dart`:

```bash
dart pub global activate nitrogen_cli   # one-time install of the `nitrogen` CLI

cd nitro_camera
nitrogen generate   # regenerates the Dart/Kotlin/C++/.mm bridges (build_runner)
nitrogen link       # wires generated native bridges into the build systems
nitrogen doctor     # verifies the plugin is production-ready
```

## 📜 License

Created by **Shreeman Arjun Sahu**. Built with ❤️ and the power of Nitro.
