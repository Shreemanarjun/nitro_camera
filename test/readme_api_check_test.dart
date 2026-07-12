/// Compile-time guard that every code sample in README.md stays valid.
///
/// Each `_readme*` function mirrors a README snippet verbatim (modulo
/// plumbing like obtaining a controller). Nothing here is executed — the
/// value is that `flutter analyze` fails if the public API drifts away
/// from what the README documents.
// ignore_for_file: unused_local_variable, unused_element, avoid_print
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

void main() {
  test('README samples compile', () {
    // Compile-only: the sample functions below are never invoked.
    expect(true, isTrue);
  });
}

// ---------------------------------------------------------------------------
// § Quick Start
// ---------------------------------------------------------------------------

class _QuickStartScreen extends StatefulWidget {
  const _QuickStartScreen();
  @override
  State<_QuickStartScreen> createState() => _QuickStartScreenState();
}

class _QuickStartScreenState extends State<_QuickStartScreen> {
  CameraController? _controller;

  Future<void> _open() async {
    await CameraController.requestCameraPermission();

    final devices = await CameraController.getAvailableCameraDevices();
    final back = devices.backCamera() ?? devices.first;

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
        FloatingActionButton(
          onPressed: () async {
            final photo = await c.takePhoto();
            debugPrint('Saved to ${photo.path}');
          },
          child: const Icon(Icons.camera),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// § Device discovery & selection
// ---------------------------------------------------------------------------

Future<void> _readmeDeviceDiscovery() async {
  final List<CameraDeviceInfo> devices = await CameraController.getAvailableCameraDevices();

  final back = devices.backCamera();
  final front = devices.frontCamera();
  final usb = devices.externalCamera();

  final device = selectCameraDevice(
    devices,
    position: CameraPosition.back,
    physicalDevices: [PhysicalDeviceType.wideAngleCamera],
  );

  // Documented CameraDeviceInfo fields.
  final d = devices.first;
  final _ = [
    d.id,
    d.name,
    d.position,
    d.lensType,
    d.sensorOrientation,
    d.minZoom,
    d.maxZoom,
    d.neutralZoom,
    d.hasFlash,
    d.hasTorch,
    d.maxPhotoWidth,
    d.maxPhotoHeight,
    d.minExposure,
    d.maxExposure,
    d.minFocusDistanceCm,
    d.isMultiCam,
    d.supportsLowLightBoost,
    d.supportsRawCapture,
    d.supportsFocus,
    d.hardwareLevel,
    d.physicalDevices,
    d.formats,
  ];
}

// ---------------------------------------------------------------------------
// § Permissions
// ---------------------------------------------------------------------------

Future<void> _readmePermissions() async {
  final PermissionStatus cam = await CameraController.requestCameraPermission();
  final PermissionStatus mic = await CameraController.requestMicrophonePermission();
  switch (cam) {
    case PermissionStatus.notDetermined:
    case PermissionStatus.granted:
    case PermissionStatus.denied:
    case PermissionStatus.restricted:
      break;
  }
}

// ---------------------------------------------------------------------------
// § Rendering the preview
// ---------------------------------------------------------------------------

Widget _readmePreviewWidgets(
  CameraController controller,
  CameraDeviceInfo device,
  Widget myOverlay,
) {
  final imperative = CameraPreview(
    controller: controller,
    mode: PreviewMode.texture,
    resizeMode: PreviewResizeMode.cover,
    child: myOverlay,
  );

  final declarative = CameraView(
    device: device,
    fps: 60,
    audio: true,
    isActive: true,
    resizeMode: PreviewResizeMode.cover,
    onInitialized: (c) => print(c.textureId),
    onError: (e) => print(e),
    child: myOverlay,
  );

  return Column(children: [imperative, declarative]);
}

// ---------------------------------------------------------------------------
// § Controller lifecycle
// ---------------------------------------------------------------------------

Future<void> _readmeLifecycle(CameraDeviceInfo device) async {
  final controller = CameraController(device: device, audio: true);
  await controller.initialize(width: 1920, height: 1080, fps: 30);

  final bool ready = controller.isInitialized;
  final int? textureId = controller.textureId;
  final int w = controller.width, h = controller.height;
  final ResolvedCameraConfig? resolved = controller.resolvedConfig;

  controller.pausePreview();
  controller.resumePreview();
  await controller.closeSession();
  await controller.dispose();
}

// ---------------------------------------------------------------------------
// § Live controls
// ---------------------------------------------------------------------------

void _readmeLiveControls(CameraController controller) {
  controller.setZoom(2.0);
  controller.focus(0.5, 0.5);
  controller.setAutoFocus(AutoFocusMode.continuous);
  controller.setExposure(0.0);
  controller.setFlash(FlashMode.auto);
}

// ---------------------------------------------------------------------------
// § Declarative configuration
// ---------------------------------------------------------------------------

Future<void> _readmeConfigure(
  CameraController controller,
  String myGlsl,
) async {
  await controller.configure(
    controller.configuration!.copyWith(
      zoom: 2.0,
      flash: FlashMode.on,
      torch: true,
      whiteBalanceKelvin: 5600,
      videoHdr: true,
      lowLightBoost: true,
      videoStabilization: VideoStabilizationMode.cinematic,
      filterShader: myGlsl,
    ),
  );
}

// ---------------------------------------------------------------------------
// § Photo capture
// ---------------------------------------------------------------------------

Future<void> _readmePhoto(CameraController controller) async {
  final PhotoResult photo = await controller.takePhoto();

  final photo2 = await controller.takePhotoWithOptions(
    const PhotoCaptureOptions(
      flash: FlashMode.auto,
      quality: QualityPrioritization.quality,
      enableShutterSound: true,
      skipMetadata: false,
      enableAutoRedEyeReduction: true,
    ),
  );

  final snap = await controller.takeSnapshot();

  // Documented PhotoResult fields.
  final _ = [
    photo.path,
    photo.width,
    photo.height,
    photo.fileSize,
    photo.orientation,
    photo.isMirrored,
    photo.timestamp,
  ];
}

// ---------------------------------------------------------------------------
// § Video recording
// ---------------------------------------------------------------------------

Future<void> _readmeRecording(CameraController controller) async {
  await controller.startRecording(
    '/path/to/output.mp4',
    options: const RecordingOptions(
      codec: 0,
      fileType: 0,
      bitRate: 0,
      maxDurationMs: 0,
      maxFileSizeBytes: 0,
    ),
  );

  controller.pauseRecording();
  controller.resumeRecording();

  final RecordingResult result = await controller.stopRecording();
  final _ = [
    result.path,
    result.durationMs,
    result.fileSize,
    result.width,
    result.height,
    result.codec,
    result.fileType,
    result.finishedReason,
  ];

  controller.cancelRecording();
  final bool recording = controller.isRecording;
}

// ---------------------------------------------------------------------------
// § Code scanning
// ---------------------------------------------------------------------------

Future<void> _readmeScanner(CameraController controller) async {
  await controller.configure(
    controller.configuration!.copyWith(
      pixelFormat: PixelFormat.yuv420,
      enableFrameProcessing: true,
    ),
  );

  final scanner = CodeScanner(
    kind: CodeScanKind.qr,
    mode: ScanMode.continuous,
    confirmationFrames: 2,
    cooldown: const Duration(milliseconds: 1500),
  );

  await scanner.start(controller.frameStream);

  scanner.results.listen((CodeResult code) {
    print('${code.format}: ${code.text}');
  });
  scanner.detections.listen((code) {});
  scanner.stats.listen((s) => print('decode ${s.elapsedMillis}ms'));

  scanner.resume();

  // Documented CodeResult members.
  scanner.results.listen((code) {
    final _ = [
      code.text,
      code.format,
      code.timestamp,
      code.isGs1,
      code.windowPoints,
      code.isbn,
    ];
  });

  await scanner.dispose();
}

// ---------------------------------------------------------------------------
// § Frame processing
// ---------------------------------------------------------------------------

// Handler MUST be top-level or static (it runs on a worker isolate):
int meanLuma(FrameData frame) {
  var sum = 0;
  for (var i = 0; i < frame.bytes.length; i += 64) {
    sum += frame.bytes[i];
  }
  return sum ~/ (frame.bytes.length ~/ 64);
}

Future<void> _readmeFrameProcessing(CameraController controller) async {
  final processor = CameraFrameProcessor<int>(meanLuma);
  await processor.start();

  controller.enableFrameProcessing();
  processor.attach(controller.frameStream);
  processor.results.listen((luma) => print('brightness $luma'));

  // Documented FrameData fields.
  int probe(FrameData f) => f.width + f.height + f.format + f.bytesPerRow + f.effectiveBytesPerRow + (f.isMirrored ? 1 : 0) + f.bytes.length;
}

// ---------------------------------------------------------------------------
// § Native ML detectors
// ---------------------------------------------------------------------------

void _readmeDetectors(CameraController controller) {
  controller.startDetector(NativeDetector.barcode);
  controller.detections.listen((DetectionResult r) {});
  controller.stopDetector();
}

// ---------------------------------------------------------------------------
// § GPU filters / shaders
// ---------------------------------------------------------------------------

void _readmeShader(CameraController controller, String glslFragmentSource) {
  controller.setFilterShader(glslFragmentSource);
}

// ---------------------------------------------------------------------------
// § Events & streams
// ---------------------------------------------------------------------------

void _readmeEvents(CameraController controller) {
  controller.events.listen((CameraSessionEvent e) {});
  final all = CameraController.allEvents;
  final drops = controller.frameDropReasons;
  final thermal = controller.thermalStates;
  final frames = controller.frameStream;
}

// ---------------------------------------------------------------------------
// § Enum reference table
// ---------------------------------------------------------------------------

const _enumTable = <dynamic>[
  [CameraPosition.front, CameraPosition.back, CameraPosition.external],
  [
    CameraLensType.unknown,
    CameraLensType.wideAngle,
    CameraLensType.ultraWideAngle,
    CameraLensType.telephoto,
  ],
  [FlashMode.off, FlashMode.on, FlashMode.auto],
  [AutoFocusMode.off, AutoFocusMode.continuous, AutoFocusMode.locked],
  [
    VideoStabilizationMode.off,
    VideoStabilizationMode.standard,
    VideoStabilizationMode.cinematic,
    VideoStabilizationMode.cinematicExtended,
    VideoStabilizationMode.auto,
  ],
  [
    QualityPrioritization.speed,
    QualityPrioritization.balanced,
    QualityPrioritization.quality,
  ],
  [VideoCodec.h264, VideoCodec.hevc],
  [VideoFileType.mp4, VideoFileType.mov],
  [PixelFormat.yuv420, PixelFormat.bgra],
  [
    CodeScanKind.qr,
    CodeScanKind.oneD,
    CodeScanKind.twoD,
    CodeScanKind.postal,
    CodeScanKind.pharma,
    CodeScanKind.all,
  ],
  [ScanMode.continuous, ScanMode.oneShot],
  [NativeDetector.barcode, NativeDetector.face],
  [PreviewMode.texture, PreviewMode.platformView, PreviewMode.impeller],
  [PreviewResizeMode.cover, PreviewResizeMode.contain],
];
