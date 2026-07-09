import Foundation

/// Shared error domain for the camera core.
///
/// vision-camera analogue: none as a type — v5 throws Nitro
/// `RuntimeError.error(withMessage:)` inline. Our FFI bridge surfaces
/// `LocalizedError.errorDescription` strings, so a single typed enum lives here.
enum CameraError: Error, LocalizedError {
    case configurationFailed
    case captureFailed
    case deviceNotFound
    case permissionDenied
    case rawNotSupported
    case captureInProgress
    case sessionNotRunning
    case captureTimedOut

    var errorDescription: String? {
        switch self {
        case .configurationFailed: return "Camera session configuration failed"
        case .captureFailed:       return "Capture failed"
        case .deviceNotFound:      return "Camera device not found"
        case .permissionDenied:    return "Camera permission denied"
        case .rawNotSupported:
            return "RAW (DNG) capture is not supported by this camera/output — no RAW pixel formats are available"
        case .captureInProgress:
            return "A capture is already in progress on this session"
        case .sessionNotRunning:
            return "The camera session is not running — start the preview before capturing"
        case .captureTimedOut:
            return "The capture timed out waiting for the camera pipeline"
        }
    }
}
