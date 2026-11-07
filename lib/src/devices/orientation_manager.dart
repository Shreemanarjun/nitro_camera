/// Physical-orientation tracking + output-orientation policy — the Dart
/// analogue of vision-camera's `OrientationManager` / `useOrientation` and the
/// `outputOrientation` camera prop.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

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
  bool _released = false;

  // The native sensor listener is one per NitroCamera, while any number of
  // managers may share it: count the started ones so the first start enables
  // it and only the last dispose disables it, and keep the latest reading so
  // a manager that starts later can replay it at once.
  static final _activeManagers = Expando<int>();
  static final _lastKnownOrientation = Expando<int>();

  OrientationManager({NitroCamera? native}) : _native = native ?? NitroCamera.instance;

  /// Physical orientation changes in degrees (0 / 90 / 180 / 270), in the
  /// platform's own convention (see [clockwiseDegrees]). A new listener first
  /// gets the current orientation when it is known (vision-camera #4150), so
  /// it never has to wait for the next rotation.
  Stream<int> get orientationStream => Stream<int>.multi((sink) {
    final current = _current;
    if (current != null) sink.add(current);
    final sub = _out.stream.listen(sink.add, onError: sink.addError, onDone: sink.close);
    sink.onCancel = sub.cancel;
  }, isBroadcast: true);

  /// Degrees (0 / 90 / 180 / 270) to rotate UI controls (flash, flip camera…)
  /// so they look upright on a portrait-locked screen as the phone turns —
  /// vision-camera's `onUIRotationChanged` (v5.2.3). Signed and shortest:
  /// `-90`, `0`, `90` or `180`; feed `turns: deg / 360` to an
  /// `AnimatedRotation`. Replays the current value like [orientationStream].
  ///
  /// [interfaceDegrees] is the app's own UI rotation, clockwise; 0 for the
  /// usual portrait-locked camera screen.
  Stream<int> uiRotationStream({int interfaceDegrees = 0}) => orientationStream.map((deg) => uiRotation(outputDegrees: clockwiseDegrees(deg), interfaceDegrees: interfaceDegrees)).distinct();

  /// [platformDegrees] from [orientationStream] as the clockwise rotation of
  /// the phone from portrait. Android's sensor already reports clockwise
  /// (90 = left edge up); iOS reports `UIDeviceOrientation` order, where 90 is
  /// `landscapeLeft` (right edge up, a counter-clockwise turn).
  static int clockwiseDegrees(int platformDegrees, {TargetPlatform? platform}) => (platform ?? defaultTargetPlatform) == TargetPlatform.iOS ? (360 - platformDegrees) % 360 : platformDegrees % 360;

  /// The signed rotation that keeps UI upright relative to the camera output
  /// (vision-camera's `getUIRotation`): `interface − output`, normalised to
  /// the shortest turn, so 270° comes back as -90° and opposites as 180°.
  /// Both inputs are clockwise degrees.
  static int uiRotation({required int outputDegrees, int interfaceDegrees = 0}) {
    final rotation = (interfaceDegrees - outputDegrees) % 360; // Dart % is non-negative
    return rotation > 180 ? rotation - 360 : rotation;
  }

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
      _lastKnownOrientation[_native] = deg;
      if (!_out.isClosed) _out.add(deg);
      final driven = _driven;
      if (driven != null && _mode == OutputOrientationMode.device) {
        driven.setTargetOrientation(deg);
      }
    });
    _current ??= _lastKnownOrientation[_native];
    final active = (_activeManagers[_native] ?? 0) + 1;
    _activeManagers[_native] = active;
    if (active == 1) _native.enableOrientationEvents(1);
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

  /// Closes the stream and releases this manager's share of the native
  /// listener, which stops once no started manager is left. Idempotent.
  Future<void> dispose() async {
    if (_started && !_released) {
      _released = true;
      final active = (_activeManagers[_native] ?? 1) - 1;
      _activeManagers[_native] = active > 0 ? active : null;
      if (active <= 0) {
        _lastKnownOrientation[_native] = null;
        _native.enableOrientationEvents(0);
      }
    }
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
  bool _released = false;

  // One native availability callback per NitroCamera, shared by every
  // observer: the first start enables it, only the last dispose disables it.
  static final _activeObservers = Expando<int>();

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
    final active = (_activeObservers[_native] ?? 0) + 1;
    _activeObservers[_native] = active;
    if (active == 1) _native.enableDeviceAvailabilityEvents(1);
  }

  /// Closes [changes] and releases this observer's share of the native
  /// callback, which stops once no started observer is left. Idempotent.
  Future<void> dispose() async {
    if (_started && !_released) {
      _released = true;
      final active = (_activeObservers[_native] ?? 1) - 1;
      _activeObservers[_native] = active > 0 ? active : null;
      if (active <= 0) _native.enableDeviceAvailabilityEvents(0);
    }
    await _sub?.cancel();
    if (!_changes.isClosed) await _changes.close();
  }
}
