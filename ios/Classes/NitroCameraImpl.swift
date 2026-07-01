import Foundation
import AVFoundation
import Combine
import Flutter

/// Real AVFoundation implementation of `HybridNitroCameraProtocol`.
///
/// Method sync/async split mirrors the generated protocol exactly: `@nitroAsync`
/// spec methods are `async throws` here; everything else is synchronous. Sync
/// methods that delegate to throwing session calls swallow errors with `try?`
/// (the bridge signature can't propagate them).
@objc(NitroCameraImpl)
public class NitroCameraImpl: NSObject, HybridNitroCameraProtocol {

    private weak var textureRegistry: FlutterTextureRegistry?
    /// Active sessions keyed by textureId.
    private var sessions = [Int64: NitraCameraSession]()
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
    //                  4=interruptionEnded 5=frameDropped
    private func emitEvent(_ type: Int64, textureId: Int64 = 0, reason: Int64 = 0, message: String = "") {
        eventSubject.send(CameraEvent(type: type, textureId: textureId, reason: reason, message: message))
    }

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

    // MARK: - Device enumeration

    public func getAvailableCameraDevicesJson() async throws -> String {
        let devices = discoverySession().devices
        let arr = devices.compactMap { deviceInfoDict(for: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    public func getAvailableCameraDevices() -> [CameraDevice] {
        return discoverySession().devices.map { deviceInfo(for: $0) }
    }

    public func getDeviceCount() -> Int64 {
        Int64(discoverySession().devices.count)
    }

    public func getDevice(index: Int64) -> CameraDevice {
        let devices = discoverySession().devices
        guard !devices.isEmpty else {
            return CameraDevice(
                id: "", name: "", position: 2, lensType: 0, sensorOrientation: 0,
                minZoom: 1, maxZoom: 1, neutralZoom: 1, hasFlash: 0, hasTorch: 0,
                maxPhotoWidth: 0, maxPhotoHeight: 0, focalLength: 0, aperture: 0)
        }
        let i = Int(max(0, min(index, Int64(devices.count - 1))))
        return deviceInfo(for: devices[i])
    }

    // MARK: - Camera lifecycle

    public func openCamera(deviceId: String, width: Int64, height: Int64, fps: Int64, enableAudio: Int64) async throws -> Int64 {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw NitraCameraError.permissionDenied
        }
        guard let avDevice = AVCaptureDevice(uniqueID: deviceId) else {
            throw NitraCameraError.deviceNotFound
        }
        guard let registry = textureRegistry else {
            throw NitraCameraError.configurationFailed
        }

        // Allocate a texture id on the main thread, then build the real session.
        let textureId: Int64 = try await MainActor.run {
            let placeholder = try NitraCameraSession(
                textureId: 0, device: avDevice, textureRegistry: registry,
                width: width, height: height, fps: fps, enableAudio: enableAudio != 0)
            return registry.register(placeholder)
        }

        let realSession = try NitraCameraSession(
            textureId: textureId, device: avDevice, textureRegistry: registry,
            width: width, height: height, fps: fps, enableAudio: enableAudio != 0)

        await MainActor.run {
            registry.unregisterTexture(textureId)
            _ = registry.register(realSession)
        }

        realSession.onFrame = { [weak self] frame in
            self?.frameSubject.send(frame)
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
        session(for: textureId)?.setFlash(mode: mode)
    }

    public func setTorch(textureId: Int64, enabled: Int64) {
        try? session(for: textureId)?.setTorch(enabled: enabled != 0)
    }

    public func setWhiteBalance(textureId: Int64, temperature: Int64) {
        try? session(for: textureId)?.setWhiteBalance(temperature: temperature)
    }

    public func setHdr(textureId: Int64, enabled: Int64) {
        try? session(for: textureId)?.setHdr(enabled: enabled != 0)
    }

    // MARK: - Photo capture

    public func takePhoto(textureId: Int64) async throws -> PhotoResult {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        return try await s.takePhoto()
    }

    // MARK: - Video recording

    public func startVideoRecording(textureId: Int64, outputPath: String) async throws {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        try await s.startVideoRecording(to: outputPath)
    }

    public func stopVideoRecording(textureId: Int64) async throws -> RecordingResult {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        return try await s.stopVideoRecording()
    }

    public func pauseRecording(textureId: Int64) {
        session(for: textureId)?.pauseVideoRecording()
    }

    public func resumeRecording(textureId: Int64) {
        session(for: textureId)?.resumeVideoRecording()
    }

    public func cancelRecording(textureId: Int64) {
        let s = session(for: textureId)
        Task { try? await s?.cancelVideoRecording() }
    }

    // MARK: - Frame processing

    public func enableFrameProcessing(textureId: Int64, enabled: Int64) {
        session(for: textureId)?.frameProcessingEnabled = (enabled != 0)
    }

    public func setFrameFormat(textureId: Int64, format: Int64) {
        session(for: textureId)?.setFrameFormat(format)
    }

    public func setSamplingRate(textureId: Int64, samplingRate: Int64) {
        session(for: textureId)?.setSamplingRate(samplingRate)
    }

    public func setFilterShader(textureId: Int64, shaderSource: String) {
        // GPU preview filter is Android-only for now; reserved on iOS.
    }

    public func updateOverlay(textureId: Int64, overlayData: Data) {
        // Reserved.
    }

    // MARK: - Declarative configuration & advanced controls

    public func configure(textureId: Int64, config: CameraConfig) async throws -> ResolvedConfig {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        try? s.setZoom(config.zoom)
        try? s.setExposure(value: config.exposure)
        s.setFlash(mode: config.flash)
        if config.torchLevel > 0 {
            s.setTorchLevel(config.torchLevel)
        } else {
            try? s.setTorch(enabled: config.torch != 0)
        }
        try? s.setWhiteBalance(temperature: config.whiteBalanceKelvin)
        try? s.setHdr(enabled: config.videoHdr != 0)
        s.setLowLightBoost(config.lowLightBoost != 0)
        try? s.setAutoFocus(mode: config.autoFocus)
        s.setVideoStabilization(config.videoStabilization)
        s.setFrameFormat(config.pixelFormat)
        s.setSamplingRate(config.samplingRate)
        s.frameProcessingEnabled = (config.enableFrameProcessing != 0)
        if config.active != 0 { s.start() } else { s.stop() }

        let afSystem: Int64 = config.autoFocus == 0 ? 0 : 2 // off vs phase-detection
        return ResolvedConfig(
            width: s.streamWidth,
            height: s.streamHeight,
            fps: s.activeFps,
            pixelFormat: s.pixelFormat,
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
            "pixelFormat": s.pixelFormat,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
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

    public func takePhotoWithOptions(textureId: Int64, options: PhotoOptions) async throws -> PhotoResult {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        let flash: AVCaptureDevice.FlashMode
        switch options.flash {
        case 1:  flash = .on
        case 2:  flash = .auto
        default: flash = .off
        }
        return try await s.takePhoto(flashMode: flash)
    }

    public func takeSnapshot(textureId: Int64) async throws -> PhotoResult {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        return try await s.takePhoto()
    }

    public func reset() {
        sessionsLock.lock()
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        sessionsLock.unlock()
    }

    // MARK: - Helpers

    private func session(for textureId: Int64) -> NitraCameraSession? {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return sessions[textureId]
    }

    private func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )
    }

    private func deviceInfoDict(for device: AVCaptureDevice) -> [String: Any] {
        let position: Int = device.position == .front ? 0 : (device.position == .back ? 1 : 2)
        let lensType: Int
        switch device.deviceType {
        case .builtInUltraWideCamera: lensType = 2
        case .builtInTelephotoCamera: lensType = 3
        default:                      lensType = 1
        }

        var maxW = 0, maxH = 0
        for fmt in device.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            if Int(dim.width) > maxW { maxW = Int(dim.width); maxH = Int(dim.height) }
        }

        let formats: [[String: Any]] = device.formats.compactMap { fmt -> [String: Any]? in
            let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard dim.width > 0 && dim.height > 0 else { return nil }
            let fpsRanges = fmt.videoSupportedFrameRateRanges
            let minFps = fpsRanges.map { $0.minFrameRate }.min() ?? 1.0
            let maxFps = fpsRanges.map { $0.maxFrameRate }.max() ?? 30.0
            var afSystem = "none"
            if #available(iOS 13.0, *) {
                switch fmt.autoFocusSystem {
                case .phaseDetection:    afSystem = "phase-detection"
                case .contrastDetection: afSystem = "contrast-detection"
                default: break
                }
            }
            return [
                "photoWidth":           maxW,
                "photoHeight":          maxH,
                "videoWidth":           Int(dim.width),
                "videoHeight":          Int(dim.height),
                "minFps":               minFps,
                "maxFps":               maxFps,
                "minISO":               device.activeFormat.minISO,
                "maxISO":               device.activeFormat.maxISO,
                "fieldOfView":          fmt.videoFieldOfView,
                "supportsVideoHdr":     fmt.isVideoHDRSupported,
                "supportsPhotoHdr":     false,
                "supportsDepthCapture": fmt.supportedDepthDataFormats.count > 0,
                "autoFocusSystem":      afSystem,
                "videoStabilizationModes": ["off", "standard"],
            ]
        }

        let minEv = Double(device.minExposureTargetBias)
        let maxEv = Double(device.maxExposureTargetBias)
        let minFocusDist = device.lensPosition > 0 ? Double(device.lensPosition) : 0.0

        return [
            "id":                   device.uniqueID,
            "name":                 device.localizedName,
            "position":             position,
            "lensType":             lensType,
            "sensorOrientation":    90,
            "minZoom":              Double(device.minAvailableVideoZoomFactor),
            "maxZoom":              Double(device.maxAvailableVideoZoomFactor),
            "neutralZoom":          1.0,
            "hasFlash":             device.hasFlash,
            "hasTorch":             device.hasTorch,
            "maxPhotoWidth":        maxW,
            "maxPhotoHeight":       maxH,
            "minExposure":          minEv,
            "maxExposure":          maxEv,
            "minFocusDistanceCm":   minFocusDist,
            "isMultiCam":           false,
            "supportsLowLightBoost": device.isLowLightBoostSupported,
            "supportsRawCapture":   false,
            "supportsFocus":        device.isFocusPointOfInterestSupported,
            "hardwareLevel":        "full",
            "physicalDevices":      [device.deviceType.rawValue],
            "formats":              formats,
        ]
    }

    private func deviceInfo(for device: AVCaptureDevice) -> CameraDevice {
        let position: Int64 = device.position == .front ? 0 : (device.position == .back ? 1 : 2)
        let lensType: Int64
        switch device.deviceType {
        case .builtInUltraWideCamera: lensType = 2
        case .builtInTelephotoCamera: lensType = 3
        default:                      lensType = 1
        }
        var maxW: Int64 = 0, maxH: Int64 = 0
        for fmt in device.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            if Int64(dim.width) > maxW { maxW = Int64(dim.width); maxH = Int64(dim.height) }
        }
        return CameraDevice(
            id: device.uniqueID,
            name: device.localizedName,
            position: position,
            lensType: lensType,
            sensorOrientation: Int64(90),
            minZoom: Double(device.minAvailableVideoZoomFactor),
            maxZoom: Double(device.maxAvailableVideoZoomFactor),
            neutralZoom: 1.0,
            hasFlash: device.hasFlash ? Int64(1) : Int64(0),
            hasTorch: device.hasTorch ? Int64(1) : Int64(0),
            maxPhotoWidth: maxW,
            maxPhotoHeight: maxH,
            focalLength: 3.5,
            aperture: 1.8
        )
    }
}
