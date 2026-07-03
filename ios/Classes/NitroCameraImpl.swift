import Foundation
import AVFoundation
import Combine
import Flutter
import UIKit

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
    //                  4=interruptionEnded 5=frameDropped 6=photoCaptureBegan
    //                  7=photoCaptureShutter 8=photoThumbnail 9=deviceConnected
    //                  10=deviceDisconnected 11=orientationChanged 12=detection
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

        // Build the session and register it as a Flutter texture ON the main
        // thread, then ADOPT the id `register()` returns. (The previous
        // placeholder/unregister/re-register dance returned a stale texture id to
        // Dart while the live session streamed to a different, unwatched id →
        // permanently black preview.)
        let realSession = try await MainActor.run { () -> NitraCameraSession in
            let s = try NitraCameraSession(
                textureId: 0, device: avDevice, textureRegistry: registry,
                width: width, height: height, fps: fps, enableAudio: enableAudio != 0)
            s.textureId = registry.register(s)
            return s
        }
        let textureId = realSession.textureId

        realSession.onFrame = { [weak self] frame in
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

    public func startVideoRecording(textureId: Int64, outputPath: String, options: RecordingOptions) async throws {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        try await s.startVideoRecording(to: outputPath, options: options)
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

    public func setDistortionCorrection(textureId: Int64, enabled: Int64) {
        session(for: textureId)?.setDistortionCorrection(enabled != 0)
    }

    public func setNativeDetector(textureId: Int64, detector: String) {
        session(for: textureId)?.setNativeDetector(detector)
    }

    // MARK: - Physical-orientation events (vision-camera's DeviceOrientationManager)
    //
    // UIDevice orientation notifications report the SENSOR-measured device
    // rotation even when the UI orientation is locked — mapped to 0/90/180/270
    // and emitted only on change (faceUp/faceDown/unknown are ignored).

    private var orientationObserver: NSObjectProtocol?
    private var lastOrientationDeg: Int64 = -1

    public func enableOrientationEvents(enabled: Int64) {
        // UIDevice orientation generation + notification delivery live on main.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if enabled != 0 {
                guard self.orientationObserver == nil else { return }
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                self.orientationObserver = NotificationCenter.default.addObserver(
                    forName: UIDevice.orientationDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self = self else { return }
                    let degrees: Int64
                    switch UIDevice.current.orientation {
                    case .portrait:           degrees = 0
                    case .landscapeLeft:      degrees = 90
                    case .portraitUpsideDown: degrees = 180
                    case .landscapeRight:     degrees = 270
                    default:                  return // faceUp/faceDown/unknown
                    }
                    guard degrees != self.lastOrientationDeg else { return }
                    self.lastOrientationDeg = degrees
                    self.emitEvent(11 /* orientationChanged */, textureId: 0, reason: degrees)
                }
            } else {
                guard let observer = self.orientationObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                self.orientationObserver = nil
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                self.lastOrientationDeg = -1
            }
        }
    }

    // MARK: - Device hot-plug (AVCaptureDevice wasConnected/wasDisconnected)

    private var deviceConnectedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?

    public func enableDeviceAvailabilityEvents(enabled: Int64) {
        if enabled != 0 {
            guard deviceConnectedObserver == nil else { return }
            let center = NotificationCenter.default
            deviceConnectedObserver = center.addObserver(
                forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil
            ) { [weak self] note in
                guard let device = note.object as? AVCaptureDevice,
                      device.hasMediaType(.video) else { return }
                self?.emitEvent(9 /* deviceConnected */, message: device.uniqueID)
            }
            deviceDisconnectedObserver = center.addObserver(
                forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: nil
            ) { [weak self] note in
                guard let device = note.object as? AVCaptureDevice,
                      device.hasMediaType(.video) else { return }
                self?.emitEvent(10 /* deviceDisconnected */, message: device.uniqueID)
            }
        } else {
            let center = NotificationCenter.default
            if let observer = deviceConnectedObserver { center.removeObserver(observer) }
            if let observer = deviceDisconnectedObserver { center.removeObserver(observer) }
            deviceConnectedObserver = nil
            deviceDisconnectedObserver = nil
        }
    }

    /// Concurrent-streaming camera combinations (multi-cam), iOS 13+ — JSON
    /// array of arrays of device uniqueIDs; "[]" where multi-cam is unsupported.
    public func getConcurrentCameraIdsJson() -> String {
        guard #available(iOS 13.0, *), AVCaptureMultiCamSession.isMultiCamSupported else {
            return "[]"
        }
        let combos = discoverySession().supportedMultiCamDeviceSets.map { set in
            set.map { $0.uniqueID }.sorted()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: combos),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    public func takePhotoWithOptions(textureId: Int64, options: PhotoOptions) async throws -> PhotoResult {
        guard let s = session(for: textureId) else { throw NitraCameraError.deviceNotFound }
        // outputFormat 1 = DNG (RAW) — dedicated ProRAW/Bayer capture path with
        // its own runtime support check (throws `rawNotSupported` when the
        // output offers no RAW pixel formats).
        if options.outputFormat == 1 { return try await s.takeDngPhoto(options: options) }
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
        return try await s.takePhoto(
            flashMode: flash,
            quality: options.qualityPrioritization,
            redEyeReduction: options.enableAutoRedEyeReduction != 0,
            location: loc)
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
        // Physical lenses + virtual (logical multi-cam) devices. Virtual devices
        // are the iOS analogue of Android's LOGICAL_MULTI_CAMERA: they expose
        // constituent physical lenses and seamless zoom switch-over.
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
        ]
        if #available(iOS 13.0, *) {
            deviceTypes.append(.builtInDualWideCamera)
            deviceTypes.append(.builtInTripleCamera)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
    }

    /// vision-camera's `physicalDevices` naming — the SAME strings as Android.
    private func lensTypeName(_ type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera: return "ultra-wide-angle-camera"
        case .builtInTelephotoCamera: return "telephoto-camera"
        default:                      return "wide-angle-camera"
        }
    }

    /// Nominal focal length in mm by lens type — AVFoundation exposes no
    /// physical focal-length API, so report a typical per-lens value (the
    /// Android side reads the real LENS_INFO_AVAILABLE_FOCAL_LENGTHS).
    private func nominalFocalLength(_ type: AVCaptureDevice.DeviceType) -> Double {
        switch type {
        case .builtInUltraWideCamera: return 1.6
        case .builtInTelephotoCamera: return 7.0
        default:                      return 4.2
        }
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

        // Physical lens composition (vision-camera's physicalDevices) — the
        // SAME strings as Android. A plain camera reports its own lens type; a
        // virtual (logical multi-cam) device lists its constituents'.
        var physicalDevices = [lensTypeName(device.deviceType)]
        var isMultiCam = false
        // neutralZoom: the first virtual-device switch-over factor (the zoom at
        // which a multi-cam device hands off between constituent lenses); 1.0
        // for plain physical cameras.
        var neutralZoom = 1.0
        if #available(iOS 13.0, *), device.isVirtualDevice {
            isMultiCam = true
            physicalDevices = device.constituentDevices.map { lensTypeName($0.deviceType) }
            if let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first {
                neutralZoom = Double(truncating: firstSwitchOver)
            }
        }

        return [
            "id":                   device.uniqueID,
            "name":                 device.localizedName,
            "position":             position,
            "lensType":             lensType,
            // 0: buffers are delivered upright (connection.videoOrientation = .portrait),
            // so the Flutter preview must NOT swap width/height.
            "sensorOrientation":    0,
            "minZoom":              Double(device.minAvailableVideoZoomFactor),
            "maxZoom":              Double(device.maxAvailableVideoZoomFactor),
            "neutralZoom":          neutralZoom,
            "hasFlash":             device.hasFlash,
            "hasTorch":             device.hasTorch,
            "maxPhotoWidth":        maxW,
            "maxPhotoHeight":       maxH,
            "minExposure":          minEv,
            "maxExposure":          maxEv,
            "minFocusDistanceCm":   minFocusDist,
            "isMultiCam":           isMultiCam,
            "supportsLowLightBoost": device.isLowLightBoostSupported,
            // Honest capability report: RAW availability on iOS is only knowable
            // from a LIVE AVCapturePhotoOutput (availableRawPhotoPixelFormatTypes
            // depends on the connected session + active format), so enumeration
            // reports false and the DNG capture path performs the real runtime
            // check — throwing a clear `rawNotSupported` error when absent.
            "supportsRawCapture":   false,
            "supportsFocus":        device.isFocusPointOfInterestSupported,
            "hardwareLevel":        "full",
            "physicalDevices":      physicalDevices,
            // Vendor extensions (Night / HDR / Bokeh...) are an Android-only
            // concept (CameraExtensionCharacteristics); always empty on iOS.
            "extensions":           [String](),
            "focalLength":          nominalFocalLength(device.deviceType),
            "aperture":             Double(device.lensAperture),
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
        // Virtual multi-cam devices: neutral zoom = first lens switch-over factor.
        var neutralZoom = 1.0
        if #available(iOS 13.0, *), device.isVirtualDevice,
           let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            neutralZoom = Double(truncating: firstSwitchOver)
        }
        return CameraDevice(
            id: device.uniqueID,
            name: device.localizedName,
            position: position,
            lensType: lensType,
            sensorOrientation: Int64(0), // upright buffers — see JSON variant above
            minZoom: Double(device.minAvailableVideoZoomFactor),
            maxZoom: Double(device.maxAvailableVideoZoomFactor),
            neutralZoom: neutralZoom,
            hasFlash: device.hasFlash ? Int64(1) : Int64(0),
            hasTorch: device.hasTorch ? Int64(1) : Int64(0),
            maxPhotoWidth: maxW,
            maxPhotoHeight: maxH,
            focalLength: nominalFocalLength(device.deviceType), // no public focal-length API
            aperture: Double(device.lensAperture)
        )
    }
}
