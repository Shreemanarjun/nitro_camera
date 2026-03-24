import AVFoundation
import CoreVideo
import Flutter

/// Manages one AVCaptureSession + Flutter texture for a single open camera.
public class NitraCameraSession: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {

    // MARK: - Public state
    public let textureId: Int64
    public private(set) var device: AVCaptureDevice

    // MARK: - Private
    private let session      = AVCaptureSession()
    private var videoOutput  = AVCaptureVideoDataOutput()
    private var photoOutput  = AVCapturePhotoOutput()
    private var movieOutput: AVCaptureMovieFileOutput?
    private weak var textureRegistry: FlutterTextureRegistry?

    private let sessionQueue = DispatchQueue(label: "dev.shreeman.nitro_camera.session", qos: .userInteractive)
    private let frameQueue   = DispatchQueue(label: "dev.shreeman.nitro_camera.frames",  qos: .userInteractive)

    // Latest camera frame (GPU path → Flutter Texture)
    private var latestPixelBuffer: CVPixelBuffer?
    private let pixelLock = NSLock()

    // Frame processing (CPU path → Nitro stream)
    var frameProcessingEnabled = false
    var onFrame: ((CameraFrame) -> Void)?

    // Photo capture continuations
    private var photoContinuation: CheckedContinuation<PhotoResult, Error>?

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
        self.textureId       = textureId
        self.device          = device
        self.textureRegistry = textureRegistry
        super.init()

        session.beginConfiguration()
        session.sessionPreset = Self.preset(width: width, height: height)

        // Video input
        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else { throw NitraCameraError.configurationFailed }
        session.addInput(videoInput)

        // Audio input
        if enableAudio, let mic = AVCaptureDevice.default(for: .audio) {
            if let audioInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
        }

        // Video output (pixel buffers for Flutter texture + frame processor)
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(videoOutput) else { throw NitraCameraError.configurationFailed }
        session.addOutput(videoOutput)

        // Photo output
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if photoOutput.isHighResolutionCaptureEnabled { photoOutput.isHighResolutionCaptureEnabled = true }

        // Target FPS
        try device.lockForConfiguration()
        let targetFps = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = targetFps
        device.activeVideoMaxFrameDuration = targetFps
        device.unlockForConfiguration()

        // Mirror front-facing camera automatically
        if let conn = videoOutput.connection(with: .video), device.position == .front {
            conn.isVideoMirrored = true
        }

        session.commitConfiguration()
    }

    // MARK: - Lifecycle

    public func start() {
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    public func close() {
        stop()
        textureRegistry?.unregisterTexture(textureId)
    }

    // MARK: - FlutterTexture

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        pixelLock.lock()
        defer { pixelLock.unlock() }
        guard let buf = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buf)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // GPU path — update Flutter texture
        pixelLock.lock()
        latestPixelBuffer = pixelBuffer
        pixelLock.unlock()
        textureRegistry?.textureFrameAvailable(textureId)

        // CPU path — optional frame processor
        guard frameProcessingEnabled, let cb = onFrame else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let w    = Int64(CVPixelBufferGetWidth(pixelBuffer))
        let h    = Int64(CVPixelBufferGetHeight(pixelBuffer))
        let size = Int64(CVPixelBufferGetDataSize(pixelBuffer))
        let ts   = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)

        // Copy pixels so Dart can safely hold the buffer
        let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size))
        memcpy(copy, baseAddr, Int(size))

        let frame = CameraFrame(
            pixels: copy,
            size: size,
            width: w,
            height: h,
            timestamp: ts,
            orientation: 0,
            textureId: textureId
        )
        cb(frame)
    }

    // MARK: - Camera controls

    func setZoom(_ zoom: Double) throws {
        try device.lockForConfiguration()
        device.videoZoomFactor = CGFloat(max(device.minAvailableVideoZoomFactor,
                                            min(zoom, device.maxAvailableVideoZoomFactor)))
        device.unlockForConfiguration()
    }

    func setFocusPoint(x: Double, y: Double) throws {
        guard device.isFocusPointOfInterestSupported else { return }
        try device.lockForConfiguration()
        device.focusPointOfInterest = CGPoint(x: x, y: y)
        device.focusMode = .autoFocus
        device.unlockForConfiguration()
    }

    func setAutoFocus(mode: Int64) throws {
        try device.lockForConfiguration()
        switch mode {
        case 1: device.focusMode = .continuousAutoFocus
        case 2: device.focusMode = .locked
        default: device.focusMode = .autoFocus
        }
        device.unlockForConfiguration()
    }

    func setExposure(value: Double) throws {
        guard device.isExposureModeSupported(.custom) else { return }
        try device.lockForConfiguration()
        // Map -1.0…1.0 to the device's min/max EV range
        let ev = Float(value) * 3.0 // typical EV range ±3
        let clamped = max(device.minExposureTargetBias, min(ev, device.maxExposureTargetBias))
        device.setExposureTargetBias(clamped, completionHandler: nil)
        device.unlockForConfiguration()
    }

    func setFlash(mode: Int64) {
        // Flash mode is applied at capture time; store it
    }

    func setTorch(enabled: Bool) throws {
        guard device.hasTorch else { return }
        try device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
    }

    func setWhiteBalance(temperature: Int64) throws {
        try device.lockForConfiguration()
        if temperature == 0 {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        } else {
            guard device.isWhiteBalanceModeSupported(.locked) else { return }
            let temp = AVCaptureDevice.WhiteBalanceTemperatureAndTint(temperature: Float(temperature), tint: 0)
            let gains = device.deviceWhiteBalanceGains(for: temp)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
        device.unlockForConfiguration()
    }

    func setHdr(enabled: Bool) throws {
        try device.lockForConfiguration()
        if #available(iOS 13.0, *) {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = enabled
        }
        device.unlockForConfiguration()
    }

    // MARK: - Photo capture

    func takePhoto(flashMode: AVCaptureDevice.FlashMode = .auto) async throws -> PhotoResult {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = device.hasFlash ? flashMode : .off
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            // default JPEG
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        guard let cont = photoContinuation else { return }
        photoContinuation = nil

        if let error = error { cont.resume(throwing: error); return }
        guard let data = photo.fileDataRepresentation() else {
            cont.resume(throwing: NitraCameraError.captureFailed); return
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try data.write(to: tmp)
            let w = Int64(photo.resolvedSettings.photoDimensions.width)
            let h = Int64(photo.resolvedSettings.photoDimensions.height)
            cont.resume(returning: PhotoResult(path: tmp.path, width: w, height: h, fileSize: Int64(data.count)))
        } catch {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Helpers

    private static func preset(width: Int64, height: Int64) -> AVCaptureSession.Preset {
        let p = max(width, height)
        if p >= 3840 { return .hd4K3840x2160 }
        if p >= 1920 { return .hd1920x1080 }
        if p >= 1280 { return .hd1280x720 }
        return .vga640x480
    }
}

enum NitraCameraError: Error {
    case configurationFailed
    case captureFailed
    case deviceNotFound
    case permissionDenied
}
