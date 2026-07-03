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

  factory CameraSessionEvent.fromNative(CameraEvent e) {
    final type = CameraEventType.values[e.type];
    // `reason` doubles as a generic integer payload (e.g. orientation
    // degrees), so only interpret it as an InterruptionReason where valid.
    final reason = (e.reason >= 0 && e.reason < InterruptionReason.values.length)
        ? InterruptionReason.values[e.reason]
        : InterruptionReason.none;
    return CameraSessionEvent(
      type: type,
      textureId: e.textureId,
      reason: reason,
      rawReason: e.reason,
      message: e.message,
    );
  }

  bool get isError => type == CameraEventType.error;
  bool get isInterruption =>
      type == CameraEventType.interruptionStarted ||
      type == CameraEventType.interruptionEnded;

  /// Degrees for [CameraEventType.orientationChanged] events, else null.
  int? get orientationDegrees =>
      type == CameraEventType.orientationChanged ? rawReason : null;

  /// The connected/disconnected camera id for hot-plug events, else null.
  String? get deviceId => (type == CameraEventType.deviceConnected ||
          type == CameraEventType.deviceDisconnected)
      ? message
      : null;

  @override
  String toString() =>
      'CameraSessionEvent(${type.name}, tid=$textureId, ${reason.name}'
      '${message.isEmpty ? '' : ', "$message"'})';
}
