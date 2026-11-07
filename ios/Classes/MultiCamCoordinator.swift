import AVFoundation

/// Simultaneous capture from several cameras (vision-camera's
/// `requiresMultiCam`). iOS runs only ONE capture session at a time, so
/// while multi-cam is enabled every CameraSession joins this one
/// AVCaptureMultiCamSession (and its serial queue) instead of creating its
/// own, wiring its inputs to its outputs with explicit connections. The
/// session runs while any member is open; the microphone belongs to the
/// first member that asked for audio.
final class MultiCamCoordinator {
    static let shared = MultiCamCoordinator()

    private let lock = NSLock()
    private var enabled = false
    private var _session: AVCaptureSession?
    let queue = DispatchQueue(label: "dev.shreeman.nitro_camera.multicam", qos: .userInteractive)
    private var members = 0
    private var audioOwner: ObjectIdentifier?

    /// Whether new sessions join the shared multi-cam session. Changing it
    /// affects sessions opened afterwards.
    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    /// The shared session, created on first use. Throws when the device has
    /// no multi-cam support.
    func join() throws -> AVCaptureSession {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CameraError.coded("MULTICAM_UNSUPPORTED: this device can't run cameras simultaneously")
        }
        lock.lock(); defer { lock.unlock() }
        let s = _session ?? AVCaptureMultiCamSession()
        _session = s
        members += 1
        return s
    }

    /// A member left; returns whether it was the last one (stop the session).
    @discardableResult
    func leave(_ member: AnyObject) -> Bool {
        lock.lock(); defer { lock.unlock() }
        members = max(0, members - 1)
        if audioOwner == ObjectIdentifier(member) { audioOwner = nil }
        if members == 0 {
            _session = nil
            return true
        }
        return false
    }

    /// Claims the microphone for [member]; false when another member has it.
    func claimAudio(_ member: AnyObject) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let owner = audioOwner, owner != ObjectIdentifier(member) { return false }
        audioOwner = ObjectIdentifier(member)
        return true
    }

    /// Adds [output] fed by [ports] with an explicit connection. Returns the
    /// connection, or nil (nothing added) when the session refuses either.
    static func connect(_ output: AVCaptureOutput, ports: [AVCaptureInput.Port],
                        in session: AVCaptureSession) -> AVCaptureConnection? {
        guard !ports.isEmpty, session.canAddOutput(output) else { return nil }
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: ports, output: output)
        guard session.canAddConnection(connection) else {
            session.removeOutput(output)
            return nil
        }
        session.addConnection(connection)
        return connection
    }

    /// The combined hardware cost (> 1.0 = the cameras can't run together).
    var hardwareCost: Float {
        lock.lock(); defer { lock.unlock() }
        return (_session as? AVCaptureMultiCamSession)?.hardwareCost ?? 0
    }
}
