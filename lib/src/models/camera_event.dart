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

  /// Why the session was interrupted (only meaningful for interruption events).
  final InterruptionReason reason;

  /// Human-readable detail for [CameraEventType.error] events.
  final String message;

  const CameraSessionEvent({
    required this.type,
    required this.textureId,
    required this.reason,
    required this.message,
  });

  factory CameraSessionEvent.fromNative(CameraEvent e) => CameraSessionEvent(
        type: CameraEventType.values[e.type],
        textureId: e.textureId,
        reason: InterruptionReason.values[e.reason],
        message: e.message,
      );

  bool get isError => type == CameraEventType.error;
  bool get isInterruption =>
      type == CameraEventType.interruptionStarted ||
      type == CameraEventType.interruptionEnded;

  @override
  String toString() =>
      'CameraSessionEvent(${type.name}, tid=$textureId, ${reason.name}'
      '${message.isEmpty ? '' : ', "$message"'})';
}
