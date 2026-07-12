/// Physical-orientation tracking + output-orientation policy — the Dart
/// analogue of vision-camera's `OrientationManager` / `useOrientation` and the
/// `outputOrientation` camera prop.
library;

import 'dart:async';

import '../controller/camera_controller.dart';
import '../nitro_camera.native.dart';

/// How captured output (photos/videos and the locked preview) should be
/// oriented. Mirrors vision-camera's `OrientationSource`.
enum OutputOrientationMode {
  /// Follow the PHYSICAL device orientation from the native sensor — rotates
  /// output correctly even when the app's UI orientation is locked.
  device,

  /// Follow the interface/preview orientation (the session's automatic
  /// follow-the-display behaviour).
  preview,
}

/// Streams the physical device orientation (0/90/180/270, sensor-derived) and
/// optionally drives a [CameraController]'s target output orientation.
///
/// ```dart
/// final orientation = OrientationManager();
/// await orientation.start();
/// orientation.orientationStream.listen((deg) => print('rotated to $deg'));
/// orientation.drive(controller, OutputOrientationMode.device);
/// ```
class OrientationManager {
  final NitroCamera _native;
  StreamSubscription<CameraEvent>? _sub;
  final StreamController<int> _out = StreamController<int>.broadcast();
  int? _current;
  CameraController? _driven;
  OutputOrientationMode _mode = OutputOrientationMode.preview;
  bool _started = false;

  OrientationManager({NitroCamera? native}) : _native = native ?? NitroCamera.instance;

  /// Physical orientation changes in degrees (0 / 90 / 180 / 270).
  Stream<int> get orientationStream => _out.stream;

  /// The last known physical orientation, or null before the first event.
  int? get currentOrientation => _current;

  /// Starts the native orientation sensor listener (idempotent).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _sub = _native.eventStream.listen((e) {
      if (!CameraSessionEvent.isKnownType(e)) return;
      final evt = CameraSessionEvent.fromNative(e);
      final deg = evt.orientationDegrees;
      if (deg == null) return;
      _current = deg;
      if (!_out.isClosed) _out.add(deg);
      final driven = _driven;
      if (driven != null && _mode == OutputOrientationMode.device) {
        driven.setTargetOrientation(deg);
      }
    });
    _native.enableOrientationEvents(1);
  }

  /// Applies orientation policy to [controller]: in [OutputOrientationMode.device]
  /// mode every physical rotation is forwarded to
  /// [CameraController.setTargetOrientation]; in preview mode the session's
  /// automatic behaviour is restored. Pass null to stop driving.
  void drive(CameraController? controller, [OutputOrientationMode mode = OutputOrientationMode.device]) {
    _driven = controller;
    _mode = mode;
    if (controller == null) return;
    if (mode == OutputOrientationMode.preview) {
      controller.setTargetOrientation(-1); // -1 = auto (follow display)
    } else if (_current != null) {
      controller.setTargetOrientation(_current!);
    }
  }

  /// Stops the native listener and closes the stream.
  Future<void> dispose() async {
    _native.enableOrientationEvents(0);
    await _sub?.cancel();
    _driven = null;
    if (!_out.isClosed) await _out.close();
  }
}

/// Watches camera hot-plug events (e.g. USB cameras) and re-enumerates the
/// device list — the analogue of vision-camera's
/// `addOnCameraDevicesChangedListener` / `useCameraDevices`.
class CameraDevicesObserver {
  final NitroCamera _native;
  StreamSubscription<CameraEvent>? _sub;
  final StreamController<CameraSessionEvent> _changes = StreamController<CameraSessionEvent>.broadcast();
  bool _started = false;

  CameraDevicesObserver({NitroCamera? native}) : _native = native ?? NitroCamera.instance;

  /// A [CameraEventType.deviceConnected] / [CameraEventType.deviceDisconnected]
  /// event per hot-plug change; [CameraSessionEvent.deviceId] names the camera.
  /// Re-query `getAvailableCameraDevicesJson` on these to refresh device lists.
  Stream<CameraSessionEvent> get changes => _changes.stream;

  /// Starts the native availability callback (idempotent).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _sub = _native.eventStream.listen((e) {
      if (!CameraSessionEvent.isKnownType(e)) return;
      final evt = CameraSessionEvent.fromNative(e);
      if (evt.type != CameraEventType.deviceConnected && evt.type != CameraEventType.deviceDisconnected) {
        return;
      }
      if (!_changes.isClosed) _changes.add(evt);
    });
    _native.enableDeviceAvailabilityEvents(1);
  }

  Future<void> dispose() async {
    _native.enableDeviceAvailabilityEvents(0);
    await _sub?.cancel();
    if (!_changes.isClosed) await _changes.close();
  }
}
