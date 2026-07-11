import Foundation
import AVFoundation
import CoreMedia
import Flutter

/// Orchestrates one AVCaptureSession for a single open camera: input/output
/// graph configuration, format negotiation, lifecycle (start/stop/close),
/// interruption + runtime-error recovery, and device controls.
///
/// Capture work is delegated to the composed outputs — `frameOutput`
/// (streaming/texture), `photoOutput` (stills) and `recorder` (movies) — which
/// the facade (`NitroCameraImpl`) routes to directly.
///
/// vision-camera analogue: ios/Hybrid Objects/HybridCameraSession.swift
/// (session graph + configuration batching on a single serial queue).
public class CameraSession: NSObject {

    // MARK: - Public state

    public private(set) var device: AVCaptureDevice
    /// Flutter texture id — forwarded from the registered FlutterTexture
    /// (`frameOutput`). Settable so the impl can adopt the id returned by
    /// `registry.register(frameOutput)`.
    public var textureId: Int64 {
        get { frameOutput.textureId }
        set { frameOutput.textureId = newValue }
    }

    // MARK: - Composed outputs (vision-camera's outputs/recording objects)

    let frameOutput: FrameOutput
    let photoOutput: PhotoOutput
    let recorder: VideoRecorder

    /// Session → impl event hook: (CameraEventType index, message). The
    /// composed outputs forward their events through this single hub.
    var onEvent: ((Int64, String) -> Void)?

    // MARK: - Private

    private let session: AVCaptureSession
    private var audioOutput: AVCaptureAudioDataOutput?
    private weak var textureRegistry: FlutterTextureRegistry?

    let sessionQueue: DispatchQueue
    let frameQueue: DispatchQueue

    // Session health observers (runtime error / interruption) — without these a
    // failed session is a silent black preview; with them the UI gets an error
    // / interruption event it can show. Removed in close().
    private var healthObservers: [NSObjectProtocol] = []
    // Set at close(): teardown of a streaming session (4K especially) can post
    // a spurious generic runtime error (-11800 "The operation could not be
    // completed") — an INTENTIONAL close must not surface it as a UI error.
    private var isClosing = false
    // Caller intent (start() vs stop()) — the media-services-reset recovery
    // below must only restart a session the app WANTS running. Mutated on
    // `sessionQueue` alongside startRunning/stopRunning.
    private var shouldBeRunning = false

    // MARK: - Init

    public init(
        textureId: Int64,
        device: AVCaptureDevice,
        textureRegistry: FlutterTextureRegistry,
        width: Int64,
        height: Int64,
        fps: Int64,
        enableAudio: Bool
    ) throws {
        self.device          = device
        self.textureRegistry = textureRegistry

        let session      = AVCaptureSession()
        let sessionQueue = DispatchQueue(label: "dev.shreeman.nitro_camera.session", qos: .userInteractive)
        let frameQueue   = DispatchQueue(label: "dev.shreeman.nitro_camera.frames",  qos: .userInteractive)
        let frameOutput  = FrameOutput(device: device,
                                       frameQueue: frameQueue,
                                       textureRegistry: textureRegistry)
        frameOutput.textureId = textureId
        let recorder = VideoRecorder(device: device,
                                     session: session,
                                     sessionQueue: sessionQueue,
                                     frameQueue: frameQueue,
                                     videoOutput: frameOutput.output)
        frameOutput.recorder = recorder
        let photoOutput = PhotoOutput(device: device,
                                      session: session,
                                      sessionQueue: sessionQueue)

        self.session      = session
        self.sessionQueue = sessionQueue
        self.frameQueue   = frameQueue
        self.frameOutput  = frameOutput
        self.recorder     = recorder
        self.photoOutput  = photoOutput
        super.init()

        // Route the outputs' events through the session's single hook.
        let emit: (Int64, String) -> Void = { [weak self] type, message in
            self?.onEvent?(type, message)
        }
        frameOutput.onEvent = emit
        photoOutput.onEvent = emit
        recorder.onEvent = emit

        session.beginConfiguration()
        // We manage formats manually via `device.activeFormat` (vision-camera-style
        // constraint negotiation below), so opt out of preset-based selection.
        session.sessionPreset = .inputPriority

        // Video input
        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else { throw CameraError.configurationFailed }
        session.addInput(videoInput)

        // Audio input + data output (so recordings can mux audio via AVAssetWriter).
        if enableAudio, let mic = AVCaptureDevice.default(for: .audio) {
            if let audioInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audioInput) {
                session.addInput(audioInput)
                let ao = AVCaptureAudioDataOutput()
                if session.canAddOutput(ao) {
                    session.addOutput(ao)
                    ao.setSampleBufferDelegate(frameOutput, queue: frameQueue)
                    audioOutput = ao
                    frameOutput.audioOutput = ao
                    recorder.hasAudioOutput = true
                }
            }
        }

        // Video output (pixel buffers for Flutter texture + frame processor)
        frameOutput.output.setSampleBufferDelegate(frameOutput, queue: frameQueue)
        frameOutput.output.alwaysDiscardsLateVideoFrames = true
        frameOutput.output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(frameOutput.output) else { throw CameraError.configurationFailed }
        session.addOutput(frameOutput.output)

        // Photo output
        photoOutput.configure(in: session)

        // Format negotiation (vision-camera v5 constraint-penalty port): choose the
        // best `activeFormat` for the requested resolution + fps (with phase-detect
        // AF / HDR-capable tiebreakers), then apply the fps within that format's
        // supported range. `activeFormat` is set first because fps/HDR depend on it.
        try device.lockForConfiguration()
        if let best = ConstraintResolver.bestFormat(for: device,
                                                    targetWidth: width,
                                                    targetHeight: height,
                                                    targetFps: fps),
           device.activeFormat != best {
            device.activeFormat = best
        }
        // Setting an unsupported frame duration throws an *uncatchable* NSException,
        // so clamp into the (chosen) active format's range.
        if fps > 0 {
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            let maxRate = ranges.map { $0.maxFrameRate }.max() ?? 30
            let minRate = ranges.map { $0.minFrameRate }.min() ?? 1
            let clamped = min(max(Double(fps), minRate), maxRate)
            let dur = CMTime(value: 1, timescale: CMTimeScale(clamped.rounded()))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
        }
        // Geometric distortion correction — default ON where supported (Android
        // parity: the ultra-wide shows heavy barrel distortion without it).
        // Toggleable later via setDistortionCorrection.
        if #available(iOS 13.0, *), device.isGeometricDistortionCorrectionSupported {
            device.isGeometricDistortionCorrectionEnabled = true
        }
        device.unlockForConfiguration()

        // Deliver UPRIGHT (portrait) buffers so the Flutter Texture isn't rotated
        // 90° (the sensor's native orientation is landscape), and mirror the front
        // camera. Both are per-connection and must be capability-guarded.
        if let conn = frameOutput.output.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if device.position == .front, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }

        session.commitConfiguration()

        // Pre-warm the photo pipeline for a default capture — must run after
        // the output has been added to the session.
        photoOutput.prewarm()

        // Log the negotiation outcome (Android createCaptureSession parity):
        // the single most useful line when a resolution switch goes black.
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        NSLog("NitroCamera open: %@ requested=%lldx%lld@%lld chosen=%dx%d@%lld",
              device.localizedName, width, height, fps, dims.width, dims.height, activeFps)

        // Session health → events. A runtime error (e.g. out-of-resources on a
        // heavy format) otherwise presents as a silent black preview.
        let center = NotificationCenter.default
        healthObservers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] note in
            guard let self = self, !self.isClosing else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = error?.localizedDescription ?? "session runtime error"
            NSLog("NitroCamera session RUNTIME ERROR: %@", message)
            // Media-services reset (-11819) kills every capture session in the
            // process; Apple's guidance (AVCam) is to simply start the session
            // again when the app still wants it running. The debounce below
            // then suppresses the error event once frames flow again.
            if let error = error, error.code == AVError.Code.mediaServicesWereReset.rawValue {
                self.sessionQueue.async { [weak self] in
                    guard let self = self, !self.isClosing, self.shouldBeRunning,
                          !self.session.isRunning else { return }
                    NSLog("NitroCamera session: media services were reset — restarting session")
                    self.session.startRunning()
                }
            }
            // Debounce: heavy-format session starts (4K, right after another
            // session's teardown) post a burst of generic -11800 errors that
            // the session survives. Only surface the error if the stream is
            // actually dead after a grace window — a transient that recovered
            // must not blank the preview / flash an error banner.
            let framesAtError = self.frameOutput.frameActivityCounter
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, !self.isClosing else { return }
                if self.frameOutput.frameActivityCounter == framesAtError {
                    self.onEvent?(2 /* error */, message)
                } else {
                    NSLog("NitroCamera session runtime error suppressed — stream recovered")
                }
            }
        })
        healthObservers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil
        ) { [weak self] note in
            guard let self = self, !self.isClosing else { return }
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? 0
            NSLog("NitroCamera session interrupted (reason=%d)", reason)
            self.onEvent?(3 /* interruptionStarted */, "reason=\(reason)")
        })
        healthObservers.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil
        ) { [weak self] _ in
            NSLog("NitroCamera session interruption ended")
            self?.onEvent?(4 /* interruptionEnded */, "")
        })
    }

    // MARK: - Lifecycle

    public func start() {
        sessionQueue.async { [weak self] in
            self?.frameOutput.firstFrameLogged = false
            self?.shouldBeRunning = true
            self?.session.startRunning()
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            self?.shouldBeRunning = false
            self?.session.stopRunning()
        }
    }

    public func close() {
        isClosing = true
        // Stop SYNCHRONOUSLY (unlike stop()): a teardown-then-reopen flow
        // (resolution switch) must not overlap this session's hardware
        // release with the successor's open — overlap interrupts the new
        // session (`AVCaptureSessionWasInterrupted` reason 3, device-in-use)
        // and can starve heavy formats (4K) outright.
        sessionQueue.sync { [weak self] in
            self?.shouldBeRunning = false
            self?.session.stopRunning()
        }
        for observer in healthObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        healthObservers.removeAll()
        // Drop the sample-buffer delegates and release the held pixel buffer so
        // the capture pool can be torn down (otherwise a reopened session leaks
        // its predecessor's buffers + pool).
        frameOutput.teardown()
        // Abort any in-flight recording so the writer doesn't outlive the
        // session, and fail its pending stop continuation.
        recorder.interrupt()
        // Resolve any in-flight photo continuation so its awaiting task
        // doesn't hang forever when the session is torn down mid-capture.
        photoOutput.cancelPending()
        textureRegistry?.unregisterTexture(textureId)
    }

    // MARK: - Camera controls

    func setZoom(_ zoom: Double) throws {
        try device.lockForConfiguration()
        device.videoZoomFactor = CGFloat(max(device.minAvailableVideoZoomFactor,
                                            min(zoom, device.maxAvailableVideoZoomFactor)))
        device.unlockForConfiguration()
    }

    func setFocusPoint(x: Double, y: Double) throws {
        guard device.isFocusPointOfInterestSupported ||
              device.isExposurePointOfInterestSupported else { return }
        try device.lockForConfiguration()
        let point = CGPoint(x: x, y: y)
        // Every AVCaptureDevice property must be gated by its `isXSupported`
        // check — setting an unsupported mode throws an *uncatchable* NSException
        // (mirrors vision-camera's guarding).
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
        }
        if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
    }

    func setAutoFocus(mode: Int64) throws {
        let target: AVCaptureDevice.FocusMode
        switch mode {
        case 1: target = .continuousAutoFocus
        case 2: target = .locked
        default: target = .autoFocus
        }
        guard device.isFocusModeSupported(target) else { return }
        try device.lockForConfiguration()
        device.focusMode = target
        device.unlockForConfiguration()
    }

    func setExposure(value: Double) throws {
        // Exposure *bias* in EV — clamp into the device's supported range.
        try device.lockForConfiguration()
        let clamped = max(device.minExposureTargetBias,
                          min(Float(value), device.maxExposureTargetBias))
        device.setExposureTargetBias(clamped, completionHandler: nil)
        device.unlockForConfiguration()
    }

    func setTorch(enabled: Bool) throws {
        guard device.hasTorch else { return }
        try device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
    }

    func setWhiteBalance(temperature: Int64) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if temperature == 0 {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            return
        }
        guard device.isWhiteBalanceModeSupported(.locked) else { return }
        // Build the target temperature DIRECTLY — do not read the device's
        // current gains and round-trip them through temperatureAndTintValues(for:).
        // On a just-opened / mid-switch device those gains are in a transitional
        // state AVFoundation rejects, raising an NSInvalidArgumentException — an
        // Obj-C exception `try?`/do-catch can't catch, so it aborts (SIGABRT).
        // This is the back→front switch crash whenever a WB temperature was set.
        let target = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: Float(temperature), tint: 0.0)
        var gains = device.deviceWhiteBalanceGains(for: target)
        // Gains for a given temperature can exceed the device's maximum (the
        // front camera's maxWhiteBalanceGain is lower than the back's) — clamp to
        // [1.0, max] or setWhiteBalanceModeLocked(with:) throws the same way.
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1.0), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
    }

    func setHdr(enabled: Bool) {
        // Toggling video HDR forces AVFoundation to reconfigure the active
        // format's pipeline — a ~300ms hardware operation. Running it inline on
        // the calling (platform/FFI) thread blocks that thread for the whole
        // reconfigure (measured 320ms). vision-camera does ALL device
        // configuration on its serial sessionQueue; do the same here so the FFI
        // call returns immediately (fire-and-forget, like the other config
        // setters) while HDR still applies on the session queue.
        sessionQueue.async { [weak self] in
            guard let self = self, self.device.activeFormat.isVideoHDRSupported else { return }
            do {
                try self.device.lockForConfiguration()
                self.device.automaticallyAdjustsVideoHDREnabled = false
                self.device.isVideoHDREnabled = enabled
                self.device.unlockForConfiguration()
            } catch {
                NSLog("NitroCamera setHdr failed: %@", error.localizedDescription)
            }
        }
    }

    func setFrameFormat(_ format: Int64) {
        frameOutput.pixelFormat = format

        let type = (format == 0) ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        // Session-graph mutation ON the session queue (vision-camera batches
        // every session mutation on its single serial queue): this is called
        // from the Dart/nitro thread and must never race a startRunning /
        // capture dispatch in flight on `sessionQueue`.
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // No-op guard: commitConfiguration rebuilds the capture pipeline even
            // for an unchanged dictionary — and the Dart boot/reapply pass calls
            // this with the format already in effect, stalling the stream (and any
            // in-flight capture) for hundreds of ms.
            let current = (self.frameOutput.output.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            guard current != type else { return }

            self.session.beginConfiguration()
            self.frameOutput.output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: type
            ]
            self.session.commitConfiguration()
        }
    }

    // MARK: - Advanced controls

    func setVideoStabilization(_ mode: Int64) {
        // Connection mutation on the session queue — same contract as
        // setFrameFormat (callers arrive on the Dart/nitro thread).
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let conn = self.frameOutput.output.connection(with: .video),
                  conn.isVideoStabilizationSupported else { return }
            conn.preferredVideoStabilizationMode = (mode == 0) ? .off : .auto
        }
    }

    func setLowLightBoost(_ enabled: Bool) {
        guard device.isLowLightBoostSupported else { return }
        try? device.lockForConfiguration()
        device.automaticallyEnablesLowLightBoostWhenAvailable = enabled
        device.unlockForConfiguration()
    }

    /// Lens geometric-distortion-correction toggle (default on — set at session
    /// setup; no-op on devices without support).
    func setDistortionCorrection(_ enabled: Bool) {
        guard #available(iOS 13.0, *),
              device.isGeometricDistortionCorrectionSupported else { return }
        try? device.lockForConfiguration()
        device.isGeometricDistortionCorrectionEnabled = enabled
        device.unlockForConfiguration()
    }

    func setTorchLevel(_ level: Double) {
        guard device.hasTorch else { return }
        try? device.lockForConfiguration()
        if level > 0 {
            try? device.setTorchModeOn(level: Float(min(max(level, 0.001), 1.0)))
        } else {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
    }

    func lockExposure(_ locked: Bool) {
        let mode: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
        guard device.isExposureModeSupported(mode) else { return }
        try? device.lockForConfiguration()
        device.exposureMode = mode
        device.unlockForConfiguration()
    }

    func lockFocus(_ locked: Bool) {
        let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
        guard device.isFocusModeSupported(mode) else { return }
        try? device.lockForConfiguration()
        device.focusMode = mode
        device.unlockForConfiguration()
    }

    func lockWhiteBalance(_ locked: Bool) {
        let mode: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
        guard device.isWhiteBalanceModeSupported(mode) else { return }
        try? device.lockForConfiguration()
        device.whiteBalanceMode = mode
        device.unlockForConfiguration()
    }

    private(set) var targetOrientationDeg: Int64 = -1
    func setTargetOrientation(_ degrees: Int64) { targetOrientationDeg = degrees }

    // MARK: - Read-back

    // Buffers are delivered PORTRAIT (connection.videoOrientation = .portrait), so
    // report the rotated dimensions — the preview sizes its aspect from these.
    var streamWidth: Int64 {
        Int64(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).height)
    }
    var streamHeight: Int64 {
        Int64(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).width)
    }
    var activeFps: Int64 {
        let d = device.activeVideoMinFrameDuration
        return d.value > 0 ? Int64(d.timescale) / Int64(d.value) : 30
    }
    var isRunning: Bool { session.isRunning }
}
