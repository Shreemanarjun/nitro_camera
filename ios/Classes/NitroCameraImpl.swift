import Foundation
import AVFoundation
import Combine
import Flutter
import UIKit

/// Real AVFoundation implementation of `HybridNitroCameraProtocol` — a thin
/// facade that routes bridge calls to the owning `CameraSession` and its
/// composed outputs (`frameOutput` / `photoOutput` / `recorder`).
///
/// vision-camera analogue: ios/Hybrid Objects/HybridCameraSession.swift acts as
/// their facade over outputs/controllers; our single flat FFI protocol plays
/// that role here (nitro generates one protocol instead of per-object specs).
///
/// Method sync/async split mirrors the generated protocol exactly: `@nitroAsync`
/// spec methods are `async throws` here; everything else is synchronous. Sync
/// methods that delegate to throwing session calls swallow errors with `try?`
/// (the bridge signature can't propagate them).
@objc(NitroCameraImpl)
public class NitroCameraImpl: NSObject, HybridNitroCameraProtocol {

    private weak var textureRegistry: FlutterTextureRegistry?
    /// Active sessions keyed by textureId.
    private var sessions = [Int64: CameraSession]()
    private let sessionsLock = NSLock()

    // Frame stream publisher (CPU path).
    private let frameSubject = PassthroughSubject<CameraFrame, Never>()
    public var frameStream: AnyPublisher<CameraFrame, Never> {
        frameSubject.eraseToAnyPublisher()
    }

    // Session lifecycle / error / interruption event stream.
    private let eventSubject = PassthroughSubject<CameraEvent, Never>()
    public var eventStream: AnyPublisher<CameraEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    // CameraEventType: 0=started 1=stopped 2=error 3=interruptionStarted
    //                  4=interruptionEnded 5=frameDropped 6=photoCaptureBegan
    //                  7=photoCaptureShutter 8=photoThumbnail 9=deviceConnected
    //                  10=deviceDisconnected 11=orientationChanged 12=detection
    private func emitEvent(_ type: Int64, textureId: Int64 = 0, reason: Int64 = 0, message: String = "") {
        eventSubject.send(CameraEvent(type: type, textureId: textureId, reason: reason, message: message))
    }

    // Device thermal monitoring (ProcessInfo.thermalState). Registered lazily
    // on first open and left running — thermal pressure is device-wide. Emits
    // thermalStateChanged with the level in `reason` (ProcessInfo.ThermalState
    // maps 1:1 to nominal/fair/serious/critical = 0..3). vision-camera has no
    // thermal handling — net addition so apps can shed load before a throttle.
    private var thermalObserver: NSObjectProtocol?
    private func emitThermal() {
        emitEvent(13 /* thermalStateChanged */, textureId: 0,
                  reason: Int64(ProcessInfo.processInfo.thermalState.rawValue))
    }
    private func ensureThermalMonitoring() {
        if thermalObserver == nil {
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.emitThermal() }
        }
        // Publish the current state on every open (thermalStateDidChange only
        // fires on CHANGE) so a consumer / reopen always sees a value.
        emitThermal()
    }

    // Physical-orientation events (vision-camera's DeviceOrientationManager).
    private lazy var orientationManager: OrientationManager = {
        let manager = OrientationManager()
        manager.onOrientationChanged = { [weak self] degrees in
            self?.emitEvent(11 /* orientationChanged */, textureId: 0, reason: degrees)
        }
        return manager
    }()

    // Device hot-plug (AVCaptureDevice wasConnected/wasDisconnected).
    private lazy var devicesObserver: CameraDevicesObserver = {
        let observer = CameraDevicesObserver()
        observer.onConnected = { [weak self] deviceId in
            self?.emitEvent(9 /* deviceConnected */, message: deviceId)
        }
        observer.onDisconnected = { [weak self] deviceId in
            self?.emitEvent(10 /* deviceDisconnected */, message: deviceId)
        }
        return observer
    }()

    public init(textureRegistry: FlutterTextureRegistry) {
        self.textureRegistry = textureRegistry
    }

    // MARK: - Permissions

    public func requestCameraPermission() async throws -> Int64 {
        return await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                continuation.resume(returning: 1)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted ? 1 : 2)
                }
            case .denied:     continuation.resume(returning: 2)
            case .restricted: continuation.resume(returning: 3)
            @unknown default: continuation.resume(returning: 2)
            }
        }
    }

    public func getCameraPermissionStatus() -> Int64 {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return 0
        case .authorized:    return 1
        case .denied:        return 2
        case .restricted:    return 3
        @unknown default:    return 2
        }
    }

    public func requestMicrophonePermission() async throws -> Int64 {
        return await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: 1)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted ? 1 : 2)
                }
            case .denied:     continuation.resume(returning: 2)
            case .restricted: continuation.resume(returning: 3)
            @unknown default: continuation.resume(returning: 2)
            }
        }
    }

    public func getMicrophonePermissionStatus() -> Int64 {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return 0
        case .authorized:    return 1
        case .denied:        return 2
        case .restricted:    return 3
        @unknown default:    return 2
        }
    }

    // MARK: - Device enumeration (see CameraDeviceInfo)

    public func getAvailableCameraDevicesJson() async throws -> String {
        return CameraDeviceInfo.devicesJson()
    }

    public func getAvailableCameraDevices() -> [CameraDevice] {
        return CameraDeviceInfo.discoverySession().devices.map { CameraDeviceInfo.deviceInfo(for: $0) }
    }

    public func getDeviceCount() -> Int64 {
        Int64(CameraDeviceInfo.discoverySession().devices.count)
    }

    public func getDevice(index: Int64) -> CameraDevice {
        let devices = CameraDeviceInfo.discoverySession().devices
        guard !devices.isEmpty else {
            return CameraDevice(
                id: "", name: "", position: 2, lensType: 0, sensorOrientation: 0,
                minZoom: 1, maxZoom: 1, neutralZoom: 1, hasFlash: 0, hasTorch: 0,
                maxPhotoWidth: 0, maxPhotoHeight: 0, focalLength: 0, aperture: 0)
        }
        let i = Int(max(0, min(index, Int64(devices.count - 1))))
        return CameraDeviceInfo.deviceInfo(for: devices[i])
    }

    public func getConcurrentCameraIdsJson() -> String {
        return CameraDeviceInfo.concurrentCameraIdsJson()
    }

    // MARK: - Camera lifecycle

    public func openCamera(deviceId: String, width: Int64, height: Int64, fps: Int64, enableAudio: Int64) async throws -> Int64 {
        // Each guard logs its reason: the bridge collapses thrown errors into a
        // 0 texture id, so without these lines an open failure is unattributable.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            NSLog("NitroCamera openCamera FAILED: camera permission not authorized")
            throw CameraError.permissionDenied
        }
        ensureThermalMonitoring()
        guard let avDevice = AVCaptureDevice(uniqueID: deviceId) else {
            NSLog("NitroCamera openCamera FAILED: no device with id %@", deviceId)
            throw CameraError.deviceNotFound
        }
        guard let registry = textureRegistry else {
            NSLog("NitroCamera openCamera FAILED: texture registry gone")
            throw CameraError.configurationFailed
        }

        // Build the session and register its FrameOutput as a Flutter texture
        // ON the main thread, then ADOPT the id `register()` returns. (The
        // previous placeholder/unregister/re-register dance returned a stale
        // texture id to Dart while the live session streamed to a different,
        // unwatched id → permanently black preview.)
        let realSession: CameraSession
        do {
            realSession = try await MainActor.run { () -> CameraSession in
                let s = try CameraSession(
                    textureId: 0, device: avDevice, textureRegistry: registry,
                    width: width, height: height, fps: fps, enableAudio: enableAudio != 0)
                s.textureId = registry.register(s.frameOutput)
                // Flutter's iOS registry hands out id 0 for the FIRST texture,
                // but 0 is the Dart-side "open failed" sentinel — returning it
                // makes every first open look failed, and the retry LEAKS this
                // session (still streaming, still holding the camera), which
                // then starves heavier reopens (the 4K black-preview report).
                // Burn id 0 and take a fresh, non-zero id.
                if s.textureId == 0 {
                    registry.unregisterTexture(0)
                    s.textureId = registry.register(s.frameOutput)
                    NSLog("NitroCamera openCamera: texture id 0 burned — reassigned id %lld", s.textureId)
                }
                return s
            }
        } catch {
            // The bridge swallows thrown errors into a 0 texture id — log the
            // real reason here or open failures are undiagnosable on device.
            NSLog("NitroCamera openCamera(%@ %lldx%lld@%lld) FAILED: %@",
                  deviceId, width, height, fps, error.localizedDescription)
            throw error
        }
        let textureId = realSession.textureId

        realSession.frameOutput.onFrame = { [weak self] frame in
            self?.frameSubject.send(frame)
        }
        realSession.onEvent = { [weak self] type, message in
            self?.emitEvent(type, textureId: textureId, message: message)
        }

        sessionsLock.lock()
        sessions[textureId] = realSession
        sessionsLock.unlock()

        realSession.start()
        emitEvent(0 /* started */, textureId: textureId)
        return textureId
    }

    public func closeCamera(textureId: Int64) async throws {
        sessionsLock.lock()
        let session = sessions.removeValue(forKey: textureId)
        sessionsLock.unlock()
        session?.close()
        emitEvent(1 /* stopped */, textureId: textureId)
    }

    public func startPreview(textureId: Int64) {
        session(for: textureId)?.start()
    }

    public func stopPreview(textureId: Int64) {
        session(for: textureId)?.stop()
    }

    public func reset() {
        sessionsLock.lock()
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        sessionsLock.unlock()
    }

    // MARK: - Camera controls

    public func setZoom(textureId: Int64, zoom: Double) {
        try? session(for: textureId)?.setZoom(zoom)
    }

    public func setFocusPoint(textureId: Int64, x: Double, y: Double) {
        try? session(for: textureId)?.setFocusPoint(x: x, y: y)
    }

    public func setAutoFocus(textureId: Int64, mode: Int64) {
        try? session(for: textureId)?.setAutoFocus(mode: mode)
    }

    public func setExposure(textureId: Int64, value: Double) {
        try? session(for: textureId)?.setExposure(value: value)
    }

    public func setFlash(textureId: Int64, mode: Int64) {
        session(for: textureId)?.photoOutput.setFlash(mode: mode)
    }

    public func setTorch(textureId: Int64, enabled: Int64) {
        try? session(for: textureId)?.setTorch(enabled: enabled != 0)
    }

    public func setWhiteBalance(textureId: Int64, temperature: Int64) {
        try? session(for: textureId)?.setWhiteBalance(temperature: temperature)
    }

    public func setHdr(textureId: Int64, enabled: Int64) {
        session(for: textureId)?.setHdr(enabled: enabled != 0)
    }

    public func setVideoStabilization(textureId: Int64, mode: Int64) {
        session(for: textureId)?.setVideoStabilization(mode)
    }

    public func setLowLightBoost(textureId: Int64, enabled: Int64) {
        session(for: textureId)?.setLowLightBoost(enabled != 0)
    }

    public func setTorchLevel(textureId: Int64, level: Double) {
        session(for: textureId)?.setTorchLevel(level)
    }

    public func lockExposure(textureId: Int64, locked: Int64) {
        session(for: textureId)?.lockExposure(locked != 0)
    }

    public func lockFocus(textureId: Int64, locked: Int64) {
        session(for: textureId)?.lockFocus(locked != 0)
    }

    public func lockWhiteBalance(textureId: Int64, locked: Int64) {
        session(for: textureId)?.lockWhiteBalance(locked != 0)
    }

    public func setTargetOrientation(textureId: Int64, degrees: Int64) {
        session(for: textureId)?.setTargetOrientation(degrees)
    }

    public func setDistortionCorrection(textureId: Int64, enabled: Int64) {
        session(for: textureId)?.setDistortionCorrection(enabled != 0)
    }

    public func setNativeDetector(textureId: Int64, detector: String) {
        session(for: textureId)?.frameOutput.setNativeDetector(detector)
    }

    // MARK: - Photo capture (routes to PhotoOutput)

    public func takePhoto(textureId: Int64) async throws -> PhotoResult {
        guard let s = session(for: textureId) else { throw CameraError.deviceNotFound }
        return try await s.photoOutput.takePhoto()
    }

    public func takePhotoWithOptions(textureId: Int64, options: PhotoOptions) async throws -> PhotoResult {
        guard let s = session(for: textureId) else { throw CameraError.deviceNotFound }
        // outputFormat 1 = DNG (RAW) — dedicated ProRAW/Bayer capture path with
        // its own runtime support check (throws `rawNotSupported` when the
        // output offers no RAW pixel formats).
        if options.outputFormat == 1 { return try await s.photoOutput.takeDngPhoto(options: options) }
        let flash: AVCaptureDevice.FlashMode
        switch options.flash {
        case 1:  flash = .on
        case 2:  flash = .auto
        default: flash = .off
        }
        // skipMetadata drops the GPS geotag — the only optional metadata we
        // attach. `enableShutterSound` is a no-op on iOS: the system plays the
        // shutter sound itself where required (no public mute on
        // AVCapturePhotoOutput; we deliberately do NOT hack audio sessions).
        let loc: (lat: Double, lon: Double, alt: Double)? =
            (options.hasLocation != 0 && options.skipMetadata == 0)
                ? (options.latitude, options.longitude, options.altitude)
                : nil
        return try await s.photoOutput.takePhoto(
            flashMode: flash,
            quality: options.qualityPrioritization,
            redEyeReduction: options.enableAutoRedEyeReduction != 0,
            location: loc)
    }

    public func takeSnapshot(textureId: Int64) async throws -> PhotoResult {
        guard let s = session(for: textureId) else { throw CameraError.deviceNotFound }
        return try await s.photoOutput.takePhoto()
    }

    // MARK: - Video recording (routes to VideoRecorder)

    public func startVideoRecording(textureId: Int64, outputPath: String, options: RecordingOptions) async throws {
        guard let s = session(for: textureId) else { throw CameraError.deviceNotFound }
        try await s.recorder.start(to: outputPath, options: options)
    }

    public func stopVideoRecording(textureId: Int64) async throws -> RecordingResult {
        guard let s = session(for: textureId) else { throw CameraError.deviceNotFound }
        return try await s.recorder.stop()
    }

    public func pauseRecording(textureId: Int64) {
        session(for: textureId)?.recorder.pause()
    }

    public func resumeRecording(textureId: Int64) {
        session(for: textureId)?.recorder.resume()
    }

    public func cancelRecording(textureId: Int64) {
        let s = session(for: textureId)
        Task { try? await s?.recorder.cancel() }
    }

    // MARK: - Frame processing (routes to FrameOutput)

    public func enableFrameProcessing(textureId: Int64, enabled: Int64) {
        session(for: textureId)?.frameOutput.frameProcessingEnabled = (enabled != 0)
    }

    public func setFrameFormat(textureId: Int64, format: Int64) {
        session(for: textureId)?.setFrameFormat(format)
    }

    public func setSamplingRate(textureId: Int64, samplingRate: Int64) {
        session(for: textureId)?.frameOutput.setSamplingRate(samplingRate)
    }

    public func setFilterShader(textureId: Int64, shaderSource: String) {
        // Apply the shader across all three outputs via Core Image (iOS used to
        // ignore it entirely): the STILL (PhotoOutput.applyFilter), and the live
        // PREVIEW + recorded VIDEO (FrameOutput filters each frame in BGRA mode).
        guard let s = session(for: textureId) else { return }
        s.photoOutput.filterShader = shaderSource
        s.frameOutput.setPreviewFilterShader(shaderSource)
    }

    public func updateOverlay(textureId: Int64, overlayData: Data) {
        // Reserved.
    }

    // MARK: - Declarative configuration

    public func configure(textureId: Int64, config: CameraConfig) async throws -> ResolvedConfig {
        guard let s = session(for: textureId) else { throw CameraError.deviceNotFound }
        try? s.setZoom(config.zoom)
        try? s.setExposure(value: config.exposure)
        s.photoOutput.setFlash(mode: config.flash)
        if config.torchLevel > 0 {
            s.setTorchLevel(config.torchLevel)
        } else {
            try? s.setTorch(enabled: config.torch != 0)
        }
        try? s.setWhiteBalance(temperature: config.whiteBalanceKelvin)
        s.setHdr(enabled: config.videoHdr != 0)
        s.setLowLightBoost(config.lowLightBoost != 0)
        try? s.setAutoFocus(mode: config.autoFocus)
        s.setVideoStabilization(config.videoStabilization)
        s.setFrameFormat(config.pixelFormat)
        s.frameOutput.setSamplingRate(config.samplingRate)
        s.frameOutput.frameProcessingEnabled = (config.enableFrameProcessing != 0)
        if config.active != 0 { s.start() } else { s.stop() }

        let afSystem: Int64 = config.autoFocus == 0 ? 0 : 2 // off vs phase-detection
        return ResolvedConfig(
            width: s.streamWidth,
            height: s.streamHeight,
            fps: s.activeFps,
            pixelFormat: s.frameOutput.pixelFormat,
            videoHdrEnabled: config.videoHdr,
            autoFocusSystem: afSystem,
            active: config.active)
    }

    public func getSessionStateJson(textureId: Int64) -> String {
        guard let s = session(for: textureId) else { return "{\"running\":false}" }
        let dict: [String: Any] = [
            "running":     s.isRunning,
            "width":       s.streamWidth,
            "height":      s.streamHeight,
            "fps":         s.activeFps,
            "pixelFormat": s.frameOutput.pixelFormat,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - Global observers (see OrientationManager / CameraDevicesObserver)

    public func enableOrientationEvents(enabled: Int64) {
        orientationManager.setEnabled(enabled != 0)
    }

    public func enableDeviceAvailabilityEvents(enabled: Int64) {
        devicesObserver.setEnabled(enabled != 0)
    }

    // MARK: - Helpers

    private func session(for textureId: Int64) -> CameraSession? {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return sessions[textureId]
    }
}
