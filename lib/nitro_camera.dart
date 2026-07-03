/// nitro_camera — a high-performance, vision-camera-style Flutter camera plugin
/// built on the Nitro FFI bridge.
///
/// Layered architecture (see `lib/src/`):
///  * `nitro_camera.native.dart` + `generated/` — the FFI/native boundary
///    (nitro spec + generated Kotlin/Swift/C++ bridges; do not move — the native
///    build systems reference these paths).
///  * `models/`        — pure data types (devices, formats, resolved config,
///                       session state, events).
///  * `configuration/` — declarative config + constraint-based format negotiation.
///  * `controller/`    — the imperative + declarative session controller.
///  * `processing/`    — isolate-based frame processing.
///  * `widgets/`       — declarative `CameraView` + `CameraPreview`.
library;

// Native boundary (low-level FFI module — most apps use the layers below).
export 'src/nitro_camera.native.dart';

// Data models.
export 'src/models/models.dart';

// Declarative configuration + negotiation.
export 'src/configuration/configuration.dart';

// Session controller.
export 'src/controller/camera_controller.dart';

// Frame processing.
export 'src/processing/frame_processor.dart';

// Code scanning (1D / 2D / QR — selectable per frame).
export 'src/scanner/code_scanner.dart';

// Widgets.
export 'src/widgets/camera_preview.dart';
export 'src/widgets/camera_view.dart';
export 'src/widgets/fps_graph.dart';
