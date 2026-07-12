import '../nitro_camera.native.dart';

/// A typed camera lifecycle / error / interruption event, parsed from the FFI
/// [CameraEvent] record delivered on `NitroCamera.eventStream`.
///
/// Mirrors vision-camera's session listeners (`onStarted` / `onStopped` /
/// `onError` / `onInterruptionStarted` / `onInterruptionEnded`).
class CameraSessionEvent {
  final CameraEventType type;

  /// The session this event belongs to (0 = not session-specific).
  final int textureId;

  /// Why the session was interrupted (only meaningful for interruption events;
  /// [InterruptionReason.none] otherwise).
  final InterruptionReason reason;

  /// The event's raw integer payload. Interruption events store the reason
  /// index here; [CameraEventType.orientationChanged] stores DEGREES
  /// (0/90/180/270) — see [orientationDegrees].
  final int rawReason;

  /// Human-readable detail for [CameraEventType.error] events; the device id
  /// for hot-plug events; the JSON payload for [CameraEventType.detection].
  final String message;

  const CameraSessionEvent({
    required this.type,
    required this.textureId,
    required this.reason,
    this.rawReason = 0,
    required this.message,
  });

  /// Whether [e]'s type index is known to this plugin version. A newer native
  /// layer can emit indices this Dart side doesn't have yet (version skew) —
  /// filter with this before [fromNative] instead of hitting a RangeError.
  static bool isKnownType(CameraEvent e) => e.type >= 0 && e.type < CameraEventType.values.length;

  factory CameraSessionEvent.fromNative(CameraEvent e) {
    if (!isKnownType(e)) {
      throw ArgumentError.value(e.type, 'e.type', 'unknown CameraEventType index — native/plugin version skew?');
    }
    final type = CameraEventType.values[e.type];
    // `reason` doubles as a generic integer payload (e.g. orientation
    // degrees), so only interpret it as an InterruptionReason where valid.
    final reason = (e.reason >= 0 && e.reason < InterruptionReason.values.length) ? InterruptionReason.values[e.reason] : InterruptionReason.none;
    return CameraSessionEvent(
      type: type,
      textureId: e.textureId,
      reason: reason,
      rawReason: e.reason,
      message: e.message,
    );
  }

  bool get isError => type == CameraEventType.error;
  bool get isInterruption => type == CameraEventType.interruptionStarted || type == CameraEventType.interruptionEnded;

  /// Degrees for [CameraEventType.orientationChanged] events, else null.
  int? get orientationDegrees => type == CameraEventType.orientationChanged ? rawReason : null;

  /// The connected/disconnected camera id for hot-plug events, else null.
  String? get deviceId => (type == CameraEventType.deviceConnected || type == CameraEventType.deviceDisconnected) ? message : null;

  /// The typed reason for a [CameraEventType.frameDropped] event, else null.
  FrameDropReason? get frameDropReason => type == CameraEventType.frameDropped ? FrameDropReason.fromMessage(message) : null;

  /// The device thermal state for a [CameraEventType.thermalStateChanged]
  /// event, else null.
  ThermalState? get thermalState => type == CameraEventType.thermalStateChanged ? ThermalState.fromLevel(rawReason) : null;

  /// Exhaustive, typed handling of an event — the ergonomic form of a sealed
  /// hierarchy (API plan §2.2) without a parallel type: each branch receives
  /// the data already decoded for that kind. Handlers not supplied fall to
  /// [orElse]. Example:
  /// ```dart
  /// e.map(
  ///   error: (msg) => showError(msg),
  ///   orientationChanged: (deg) => rotateOverlay(deg),
  ///   thermalChanged: (state) => if (state == ThermalState.serious) dropFps(),
  ///   orElse: () {},
  /// );
  /// ```
  T map<T>({
    required T Function() orElse,
    T Function()? started,
    T Function()? stopped,
    T Function(String message)? error,
    T Function(InterruptionReason reason, bool ended)? interruption,
    T Function(int degrees)? orientationChanged,
    T Function(String deviceId, bool connected)? deviceHotplug,
    T Function(FrameDropReason reason)? frameDropped,
    T Function(ThermalState state)? thermalChanged,
    T Function(String json)? detection,
  }) {
    switch (type) {
      case CameraEventType.started:
        return started?.call() ?? orElse();
      case CameraEventType.stopped:
        return stopped?.call() ?? orElse();
      case CameraEventType.error:
        return error?.call(message) ?? orElse();
      case CameraEventType.interruptionStarted:
        return interruption?.call(reason, false) ?? orElse();
      case CameraEventType.interruptionEnded:
        return interruption?.call(reason, true) ?? orElse();
      case CameraEventType.orientationChanged:
        return orientationChanged?.call(rawReason) ?? orElse();
      case CameraEventType.deviceConnected:
        return deviceHotplug?.call(message, true) ?? orElse();
      case CameraEventType.deviceDisconnected:
        return deviceHotplug?.call(message, false) ?? orElse();
      case CameraEventType.frameDropped:
        return frameDropped?.call(FrameDropReason.fromMessage(message)) ?? orElse();
      case CameraEventType.thermalStateChanged:
        return thermalChanged?.call(ThermalState.fromLevel(rawReason)) ?? orElse();
      case CameraEventType.detection:
        return detection?.call(message) ?? orElse();
      case CameraEventType.photoCaptureBegan:
      case CameraEventType.photoCaptureShutter:
      case CameraEventType.photoThumbnail:
        return orElse();
    }
  }

  @override
  String toString() =>
      'CameraSessionEvent(${type.name}, tid=$textureId, ${reason.name}'
      '${message.isEmpty ? '' : ', "$message"'})';
}

/// Why the pipeline dropped a frame — the typed form of a
/// [CameraEventType.frameDropped] event's message (vision-camera's
/// `onFrameDropped` reason).
enum FrameDropReason {
  /// The frame arrived too late to be processed (a slow frame processor /
  /// backpressure). iOS `kCMSampleBufferDroppedFrameReason_FrameWasLate`.
  frameWasLate,

  /// The capture pool ran out of buffers (the app is holding frames too long).
  /// iOS `..._OutOfBuffers`.
  outOfBuffers,

  /// A pipeline discontinuity (e.g. format/orientation change). iOS
  /// `..._Discontinuity`.
  discontinuity,

  /// The reason string wasn't recognised.
  unknown;

  /// Parses the native drop-reason [message] (iOS
  /// `kCMSampleBufferDroppedFrameReason_*`, Android's equivalent tag).
  static FrameDropReason fromMessage(String message) {
    final s = message.toLowerCase();
    if (s.contains('late')) return frameWasLate;
    if (s.contains('buffer')) return outOfBuffers;
    if (s.contains('discontinu')) return discontinuity;
    return unknown;
  }
}

/// Device thermal pressure — the normalized form of a
/// [CameraEventType.thermalStateChanged] event's level. Apps should shed load
/// (lower fps / resolution, stop HDR) as this climbs. Mirrors iOS
/// `ProcessInfo.ThermalState`; Android `PowerManager` thermal statuses are
/// mapped onto the same four levels.
enum ThermalState {
  /// No thermal pressure.
  nominal,

  /// Slightly elevated — a good point to proactively reduce load.
  fair,

  /// The system is actively shedding performance; reduce capture load.
  serious,

  /// Critical — the device may throttle or shut the camera down; stop heavy work.
  critical;

  /// Maps a native thermal level (0..3) to a [ThermalState].
  static ThermalState fromLevel(int level) => (level >= 0 && level < values.length) ? values[level] : nominal;
}
