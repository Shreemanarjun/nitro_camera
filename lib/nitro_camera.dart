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

// Native boundary — CURATED vocabulary only: the enums that are part of the
// public API plus the FFI types that still appear in high-level signatures.
// The raw module (NitroCamera, FFI structs, codec extensions) is deliberately
// not exported here; import `package:nitro_camera/native.dart` for it.
export 'src/nitro_camera.native.dart'
    show
        // Public-vocabulary enums.
        CameraPosition,
        CameraLensType,
        FlashMode,
        AutoFocusMode,
        PermissionStatus,
        VideoStabilizationMode,
        QualityPrioritization,
        VideoCodec,
        VideoFileType,
        CameraEventType,
        InterruptionReason,
        // FFI types used in high-level signatures (stable Dart wrappers are
        // planned — docs/API_IMPROVEMENT_PLAN.md §2.5).
        CameraFrame,
        CameraEvent,
        PhotoResult,
        RecordingResult,
        RecordingOptions;

// Data models.
export 'src/models/models.dart';

// Declarative configuration + negotiation.
export 'src/configuration/configuration.dart';

// Device selection helpers (getCameraDevice parity).
export 'src/devices/device_selector.dart';

// Orientation manager + hot-plug device observer.
export 'src/devices/orientation_manager.dart';

// Session controller.
export 'src/controller/camera_controller.dart';

// Frame processing.
export 'src/processing/frame_processor.dart';
export 'src/processing/frame_processor_plugin.dart';

// Code scanning (1D / 2D / QR — selectable per frame).
export 'src/scanner/code_scanner.dart';
export 'src/scanner/scan_codes_plugin.dart';

// Widgets. (Debug HUDs like the FPS graph live in
// `package:nitro_camera/debug.dart`.)
export 'src/widgets/camera_preview.dart';
export 'src/widgets/camera_view.dart';
