/// Typed camera errors — the Dart analogue of vision-camera's `CameraError`
/// taxonomy (`domain/code` strings like `session/camera-not-ready`).
///
/// Every failure the plugin surfaces is a [CameraException] subtype carrying a
/// stable, matchable [code] (`domain/name`) plus a human-readable [message].
/// Match on the subtype for coarse handling (permission → settings deeplink,
/// device → retry, capture → toast) and on [code] for precise cases.
library;

/// Base type for every error surfaced by nitro_camera.
sealed class CameraException implements Exception {
  /// Stable machine-matchable identifier, `domain/name` — e.g.
  /// `session/not-initialized`, `device/open-failed`, `capture/timed-out`.
  /// The set of codes only grows; existing codes never change meaning.
  final String code;

  /// Human-readable detail (native error text where available).
  final String message;

  /// The originating error, when this wraps a lower-level failure.
  final Object? cause;

  const CameraException(this.code, this.message, {this.cause});

  @override
  String toString() => '$runtimeType($code): $message';
}

/// Camera / microphone permission is missing or was denied.
final class PermissionException extends CameraException {
  const PermissionException(super.code, super.message, {super.cause});

  /// `permission/camera-denied`
  factory PermissionException.cameraDenied() => const PermissionException('permission/camera-denied', 'Camera permission was denied.');

  /// `permission/microphone-denied`
  factory PermissionException.microphoneDenied() => const PermissionException('permission/microphone-denied', 'Microphone permission was denied.');
}

/// The camera device could not be opened or disappeared.
final class DeviceException extends CameraException {
  const DeviceException(super.code, super.message, {super.cause});

  /// `device/open-failed` — the HAL rejected the open (busy, wedged, or the
  /// id is unknown). Usually transient; retry with backoff.
  factory DeviceException.openFailed(String deviceId) => DeviceException('device/open-failed', 'openCamera failed for device $deviceId');
}

/// The session is in the wrong state for the requested operation, or native
/// session configuration failed.
final class SessionException extends CameraException {
  const SessionException(super.code, super.message, {super.cause});

  /// `session/not-initialized` — a control/capture call before `initialize()`
  /// completed (or after `dispose()`).
  factory SessionException.notInitialized() => const SessionException('session/not-initialized', 'CameraController is not initialised. Call initialize() first.');

  /// `session/malformed-payload` — the native layer returned data this plugin
  /// version could not parse (native/plugin version skew).
  factory SessionException.malformedPayload(String what, Object cause) => SessionException('session/malformed-payload', 'Malformed $what payload from native: $cause', cause: cause);

  /// `session/native-error` — an error event emitted by the running native
  /// session (interruption, stream failure, ...).
  factory SessionException.nativeError(String message) => SessionException('session/native-error', message.isEmpty ? 'camera error' : message);
}

/// A photo capture failed.
final class CaptureException extends CameraException {
  const CaptureException(super.code, super.message, {super.cause});
}

/// A video recording failed.
final class RecorderException extends CameraException {
  const RecorderException(super.code, super.message, {super.cause});
}
