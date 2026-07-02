import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import ImageIO
import Flutter

/// Manages one AVCaptureSession + Flutter texture for a single open camera.
public class NitraCameraSession: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {

    // MARK: - Public state
    // Settable so the impl can adopt the id returned by `registry.register(self)`.
    public var textureId: Int64
    public private(set) var device: AVCaptureDevice

    // MARK: - Private
    private let session      = AVCaptureSession()
    private var videoOutput  = AVCaptureVideoDataOutput()
    private var photoOutput  = AVCapturePhotoOutput()
    // Recording — vision-camera-style AVAssetWriter `RecordingSession`. Records
    // from the existing video-data output (+ an audio-data output) and NEVER
    // adds/removes an output on the running session (which is what causes the
    // FigCapture interruptions of the old AVCaptureMovieFileOutput approach).
    private var audioOutput: AVCaptureAudioDataOutput?
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var isWriting = false
    private var recordingPaused = false
    private var movieContinuation: CheckedContinuation<RecordingResult, Error>?
    private weak var textureRegistry: FlutterTextureRegistry?

    private let sessionQueue = DispatchQueue(label: "dev.shreeman.nitro_camera.session", qos: .userInteractive)
    private let frameQueue   = DispatchQueue(label: "dev.shreeman.nitro_camera.frames",  qos: .userInteractive)

    // Latest camera frame (GPU path → Flutter Texture)
    private var latestPixelBuffer: CVPixelBuffer?
    private let pixelLock = NSLock()

    // CPU path — ONE reused frame buffer (never per-frame allocate; that leaks
    // the whole camera stream. Mirrors the Android `directBuffer`. Freed in deinit.)
    private var frameBuffer: UnsafeMutablePointer<UInt8>?
    private var frameBufferCapacity: Int = 0

    // Frame processing (CPU path → Nitro stream)
    var frameProcessingEnabled = false
    var onFrame: ((CameraFrame) -> Void)?
    /// Session → impl event hook: (CameraEventType index, message).
    var onEvent: ((Int64, String) -> Void)?

    // Recording limits / geotag captured at start.
    private var recordingMaxDurationMs: Int64 = 0
    private var recordingMaxFileSizeBytes: Int64 = 0
    private var recordingStartPTS: CMTime = .invalid
    private var recordingSizeCheckTick = 0
    // Pending GPS geotag for the next photo (EXIF injection in the delegate).
    private var pendingPhotoLocation: (lat: Double, lon: Double, alt: Double)?
    private let ciContext = CIContext()

    // Modernized properties for per-frame analysis
    var samplingRate: Int64 = 1
    var pixelFormat: Int64 = 1 // 0: YUV/Luma, 1: BGRA
    private var frameCounter: Int64 = 0

    // Photo capture continuations
    private var photoContinuation: CheckedContinuation<PhotoResult, Error>?

    // Serialises access to the capture continuations so a continuation is never
    // leaked (set-but-never-resumed) or double-resumed (which is fatal) when a
    // stop / delegate / teardown race.
    private let captureLock = NSLock()

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
        // We manage formats manually via `device.activeFormat` (vision-camera-style
        // constraint negotiation below), so opt out of preset-based selection.
        session.sessionPreset = .inputPriority

        // Video input
        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else { throw NitraCameraError.configurationFailed }
        session.addInput(videoInput)

        // Audio input + data output (so recordings can mux audio via AVAssetWriter).
        if enableAudio, let mic = AVCaptureDevice.default(for: .audio) {
            if let audioInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audioInput) {
                session.addInput(audioInput)
                let ao = AVCaptureAudioDataOutput()
                if session.canAddOutput(ao) {
                    session.addOutput(ao)
                    ao.setSampleBufferDelegate(self, queue: frameQueue)
                    audioOutput = ao
                }
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
        photoOutput.isHighResolutionCaptureEnabled = true
        // Opt in to the full quality range so per-shot settings can request up to
        // `.quality` (requesting above the output's max throws at capture time).
        if #available(iOS 13.0, *) {
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        // Format negotiation (vision-camera v5 constraint-penalty port): choose the
        // best `activeFormat` for the requested resolution + fps (with phase-detect
        // AF / HDR-capable tiebreakers), then apply the fps within that format's
        // supported range. `activeFormat` is set first because fps/HDR depend on it.
        try device.lockForConfiguration()
        if let best = Self.bestFormat(for: device,
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
        device.unlockForConfiguration()

        // Deliver UPRIGHT (portrait) buffers so the Flutter Texture isn't rotated
        // 90° (the sensor's native orientation is landscape), and mirror the front
        // camera. Both are per-connection and must be capability-guarded.
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if device.position == .front, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
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
        // Drop the sample-buffer delegate and release the held pixel buffer so
        // the capture pool can be torn down (otherwise a reopened session leaks
        // its predecessor's buffers + pool).
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        onFrame = nil
        frameProcessingEnabled = false
        pixelLock.lock()
        latestPixelBuffer = nil
        pixelLock.unlock()
        // Abort any in-flight recording so the writer doesn't outlive the session.
        isWriting = false
        if let w = assetWriter, w.status == .writing { w.cancelWriting() }
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        // Resolve any in-flight capture continuations so their awaiting tasks
        // don't hang forever when the session is torn down mid-capture.
        captureLock.lock()
        let mc = movieContinuation; movieContinuation = nil
        let pc = photoContinuation; photoContinuation = nil
        captureLock.unlock()
        mc?.resume(throwing: NitraCameraError.captureFailed)
        pc?.resume(throwing: NitraCameraError.captureFailed)
        textureRegistry?.unregisterTexture(textureId)
    }

    deinit {
        frameBuffer?.deallocate()
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
        // Audio sample buffers (from the audio-data output) → the recording only.
        if output === audioOutput {
            appendAudioSample(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // GPU path — update Flutter texture
        pixelLock.lock()
        latestPixelBuffer = pixelBuffer
        pixelLock.unlock()
        textureRegistry?.textureFrameAvailable(textureId)

        // Recording path — feed the AVAssetWriter (runs on this same frameQueue).
        appendVideoSample(sampleBuffer)

        // CPU path — optional frame processor
        guard frameProcessingEnabled, let cb = onFrame else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let ts   = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)

        // 1. Smart Backpressure (Frame Skipping)
        frameCounter += 1
        if frameCounter % samplingRate != 0 { return }

        // 2. Read the pixels. Planar (YUV) → plane 0 = the luma/Y plane (what the
        // barcode scanner wants). Non-planar (BGRA) → the plane APIs return NULL,
        // so use the non-plane variants. Getting this wrong drops every frame.
        let w: Int64
        let h: Int64
        let rowBytes: Int
        let baseAddr: UnsafeMutableRawPointer?
        if CVPixelBufferIsPlanar(pixelBuffer) {
            w        = Int64(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0))
            h        = Int64(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
            rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        } else {
            w        = Int64(CVPixelBufferGetWidth(pixelBuffer))
            h        = Int64(CVPixelBufferGetHeight(pixelBuffer))
            rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer)
        }
        let size = Int64(rowBytes * Int(h))

        guard let addr = baseAddr else { return }

        // Copy into the REUSED buffer (grow-only). Dart reads `pixels` as a
        // zero-copy borrow inside the stream listener and copies it out
        // (TransferableTypedData) before the next frame reuses this memory.
        let n = Int(size)
        if frameBuffer == nil || frameBufferCapacity < n {
            frameBuffer?.deallocate()
            frameBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            frameBufferCapacity = n
        }
        guard let copy = frameBuffer else { return }
        memcpy(copy, addr, n)

        let frame = CameraFrame(
            pixels: copy,
            size: size,
            width: w,
            height: h,
            timestamp: ts,
            orientation: 0,
            textureId: textureId,
            bytesPerRow: Int64(rowBytes),
            pixelFormat: Int64(pixelFormat),
            isMirrored: device.position == .front ? 1 : 0
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
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } else {
            guard device.isWhiteBalanceModeSupported(.locked) else {
                device.unlockForConfiguration()
                return
            }
            let currentGains = device.deviceWhiteBalanceGains
            var temp = device.temperatureAndTintValues(for: currentGains)
            temp.temperature = Float(temperature)
            temp.tint = 0.0
            let gains = device.deviceWhiteBalanceGains(for: temp)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
        device.unlockForConfiguration()
    }

    func setHdr(enabled: Bool) throws {
        guard device.activeFormat.isVideoHDRSupported else { return }
        try device.lockForConfiguration()
        device.automaticallyAdjustsVideoHDREnabled = false
        device.isVideoHDREnabled = enabled
        device.unlockForConfiguration()
    }

    func setFrameFormat(_ format: Int64) {
        self.pixelFormat = format

        session.beginConfiguration()
        let type = (format == 0) ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: type
        ]
        session.commitConfiguration()
    }

    func setSamplingRate(_ rate: Int64) {
        self.samplingRate = max(1, rate)
    }

    // MARK: - Advanced controls

    func setVideoStabilization(_ mode: Int64) {
        guard let conn = videoOutput.connection(with: .video),
              conn.isVideoStabilizationSupported else { return }
        conn.preferredVideoStabilizationMode = (mode == 0) ? .off : .auto
    }

    func setLowLightBoost(_ enabled: Bool) {
        guard device.isLowLightBoostSupported else { return }
        try? device.lockForConfiguration()
        device.automaticallyEnablesLowLightBoostWhenAvailable = enabled
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

    // MARK: - Photo capture

    func takePhoto(flashMode: AVCaptureDevice.FlashMode = .auto,
                   quality: Int64 = 1,
                   redEyeReduction: Bool = false,
                   location: (lat: Double, lon: Double, alt: Double)? = nil) async throws -> PhotoResult {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = device.hasFlash ? flashMode : .off

        if #available(iOS 13.0, *) {
            // Map 0/1/2 → speed/balanced/quality, then CLAMP to the output's max
            // (a request above `maxPhotoQualityPrioritization` throws at capture).
            let requested: AVCapturePhotoOutput.QualityPrioritization
            switch quality {
            case 0:  requested = .speed
            case 2:  requested = .quality
            default: requested = .balanced
            }
            let capped = min(requested.rawValue,
                             photoOutput.maxPhotoQualityPrioritization.rawValue)
            settings.photoQualityPrioritization =
                AVCapturePhotoOutput.QualityPrioritization(rawValue: capped) ?? .balanced
        }
        if redEyeReduction, photoOutput.isAutoRedEyeReductionSupported {
            settings.isAutoRedEyeReductionEnabled = true
        }
        // Request a low-res preview buffer so we can emit a fast thumbnail.
        if let previewType = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewType,
                kCVPixelBufferWidthKey as String: 256,
                kCVPixelBufferHeightKey as String: 256,
            ]
        }
        pendingPhotoLocation = location

        return try await withCheckedThrowingContinuation { continuation in
            captureLock.lock()
            photoContinuation = continuation
            captureLock.unlock()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // Shutter-timing callbacks → events (vision-camera onWill{Begin,Capture}Photo).
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onEvent?(6 /* photoCaptureBegan */, "")
    }
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onEvent?(7 /* photoCaptureShutter */, "")
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        captureLock.lock()
        let maybeCont = photoContinuation
        photoContinuation = nil
        captureLock.unlock()
        let location = pendingPhotoLocation
        pendingPhotoLocation = nil

        // Fast low-res thumbnail from the embedded preview buffer → event, so the
        // UI can show the shot before the full-res JPEG is written.
        if let preview = photo.previewPixelBuffer, let onEvent = onEvent {
            let ci = CIImage(cvPixelBuffer: preview)
            if let jpeg = ciContext.jpegRepresentation(
                of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) {
                let thumbURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "_thumb.jpg")
                if (try? jpeg.write(to: thumbURL)) != nil {
                    onEvent(8 /* photoThumbnail */, thumbURL.path)
                }
            }
        }

        guard let cont = maybeCont else { return }

        if let error = error { cont.resume(throwing: error); return }
        guard let raw = photo.fileDataRepresentation() else {
            cont.resume(throwing: NitraCameraError.captureFailed); return
        }
        // Inject GPS EXIF if a geotag was supplied.
        let data = location.flatMap {
            Self.jpegWithGPS(raw, lat: $0.lat, lon: $0.lon, alt: $0.alt)
        } ?? raw

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try data.write(to: tmp)
            let w = Int64(photo.resolvedSettings.photoDimensions.width)
            let h = Int64(photo.resolvedSettings.photoDimensions.height)
            cont.resume(returning: PhotoResult(
                path: tmp.path,
                width: w,
                height: h,
                fileSize: Int64(data.count),
                orientation: Int64(device.position == .front ? 0 : 90),
                isMirrored: device.position == .front ? 1 : 0,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            ))
        } catch {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Video recording (AVAssetWriter `RecordingSession` — vision-camera style)
    //
    // All recording-state mutation + reads happen on `frameQueue`, so the capture
    // callbacks and start/stop never race. The running session is never touched.

    func startVideoRecording(to path: String, options: RecordingOptions) async throws {
        guard !isWriting, assetWriter == nil else { throw NitraCameraError.captureFailed }

        let fileType: AVFileType = (options.fileType == 1) ? .mov : .mp4
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        // GPS geotag → QuickTime movie metadata.
        if options.hasLocation != 0 {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = Self.iso6709(lat: options.latitude,
                                      lon: options.longitude,
                                      alt: options.altitude) as NSString
            writer.metadata = [item]
        }

        // Video settings — start from what the output recommends (correct size),
        // then override codec + bit-rate per the options.
        var videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: fileType)
            ?? [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: streamWidth,
                AVVideoHeightKey: streamHeight,
            ]
        videoSettings[AVVideoCodecKey] = (options.codec == 1)
            ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        if options.bitRate > 0 {
            var compression = (videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
            compression[AVVideoAverageBitRateKey] = options.bitRate
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else { throw NitraCameraError.configurationFailed }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) { writer.add(ai); aInput = ai }
        }

        // Publish on the frame queue so captureOutput sees a consistent state.
        frameQueue.sync {
            self.assetWriter = writer
            self.videoWriterInput = vInput
            self.audioWriterInput = aInput
            self.recordingURL = url
            self.recordingStartTime = Date()
            self.recordingStartPTS = .invalid
            self.recordingMaxDurationMs = options.maxDurationMs
            self.recordingMaxFileSizeBytes = options.maxFileSizeBytes
            self.recordingPaused = false
            self.isWriting = true
        }
    }

    /// ISO-6709 location string for QuickTime metadata, e.g. `+37.7749-122.4194+010.000/`.
    private static func iso6709(lat: Double, lon: Double, alt: Double) -> String {
        String(format: "%+09.5f%+010.5f%+.3f/", lat, lon, alt)
    }

    /// Re-encodes JPEG [data] with a GPS EXIF dictionary added.
    private static func jpegWithGPS(_ data: Data, lat: Double, lon: Double, alt: Double) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(src) else { return nil }
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(lat),
            kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(lon),
            kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude: abs(alt),
            kCGImagePropertyGPSAltitudeRef: alt >= 0 ? 0 : 1,
        ]
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(
            dest, src, 0, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Appends a video frame to the writer (on `frameQueue`). Anchors the writer's
    /// session on the first frame so the timeline starts at t=0.
    private func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, !recordingPaused,
              let writer = assetWriter, let input = videoWriterInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            recordingStartPTS = pts
        }
        if writer.status == .writing, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }

        // Auto-stop on the configured limits (vision-camera's maxDuration/maxFileSize).
        if recordingMaxDurationMs > 0, recordingStartPTS.isValid {
            let elapsedMs = Int64(CMTimeGetSeconds(pts - recordingStartPTS) * 1000)
            if elapsedMs >= recordingMaxDurationMs { autoStopRecording(); return }
        }
        if recordingMaxFileSizeBytes > 0 {
            recordingSizeCheckTick += 1
            if recordingSizeCheckTick % 15 == 0, let url = recordingURL {
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
                if size >= recordingMaxFileSizeBytes { autoStopRecording() }
            }
        }
    }

    /// Finalises the recording on a duration/size limit (on `frameQueue`) and
    /// emits a `stopped` event carrying the file path (there's no pending
    /// `stopVideoRecording` continuation in this path).
    private func autoStopRecording() {
        guard isWriting, let writer = assetWriter else { return }
        isWriting = false
        let url = recordingURL
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            self.frameQueue.async {
                self.assetWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.recordingURL = nil
            }
            if writer.status == .completed, let url = url {
                self.onEvent?(1 /* stopped */, url.path)
            } else {
                self.onEvent?(2 /* error */, writer.error?.localizedDescription ?? "recording failed")
            }
        }
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, !recordingPaused,
              let writer = assetWriter, writer.status == .writing,
              let input = audioWriterInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func stopVideoRecording() async throws -> RecordingResult {
        return try await withCheckedThrowingContinuation { continuation in
            frameQueue.async {
                self.captureLock.lock()
                let stopping = self.movieContinuation != nil
                guard self.isWriting, let writer = self.assetWriter, !stopping else {
                    self.captureLock.unlock()
                    // Nothing recording / a stop already in flight → fail fast
                    // instead of leaking the continuation.
                    continuation.resume(throwing: NitraCameraError.captureFailed)
                    return
                }
                self.movieContinuation = continuation
                self.captureLock.unlock()

                self.isWriting = false
                let start = self.recordingStartTime
                let url = self.recordingURL
                self.videoWriterInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()
                writer.finishWriting {
                    let cont = self.takeMovieContinuation()
                    self.frameQueue.async {
                        self.assetWriter = nil
                        self.videoWriterInput = nil
                        self.audioWriterInput = nil
                        self.recordingURL = nil
                    }
                    guard let cont = cont else { return }
                    if writer.status == .completed, let url = url {
                        let duration = Int64((Date().timeIntervalSince(start ?? Date())) * 1000)
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                        cont.resume(returning: RecordingResult(
                            path: url.path, durationMs: duration, fileSize: size))
                    } else {
                        cont.resume(throwing: writer.error ?? NitraCameraError.captureFailed)
                    }
                }
            }
        }
    }

    func pauseVideoRecording()  { recordingPaused = true }
    func resumeVideoRecording() { recordingPaused = false }

    func cancelVideoRecording() async throws {
        takeMovieContinuation()?.resume(throwing: NitraCameraError.captureFailed)
        let url = recordingURL
        frameQueue.sync {
            self.isWriting = false
            if let w = self.assetWriter, w.status == .writing { w.cancelWriting() }
            self.assetWriter = nil
            self.videoWriterInput = nil
            self.audioWriterInput = nil
            self.recordingURL = nil
        }
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }

    private func takeMovieContinuation() -> CheckedContinuation<RecordingResult, Error>? {
        captureLock.lock(); defer { captureLock.unlock() }
        let c = movieContinuation; movieContinuation = nil; return c
    }

    // MARK: - Helpers

    /// Picks the best `AVCaptureDevice.Format` by summing weighted penalties
    /// (lower = better) — a faithful port of vision-camera v5's `ConstraintResolver`.
    /// Priority order (higher weight dominates): resolution → fps → phase-detect
    /// autofocus → HDR-capable → high photo quality.
    ///
    /// Resolution penalty = `100 × relativeAspectDiff` (past a 2% tolerance) +
    /// `|ln(actualPixels / targetPixels)|` (scale-invariant). FPS penalty = 0 in
    /// range, else the raw fps-distance to the nearest supported range. The others
    /// are small integer penalties, so resolution + fps decide the winner and the
    /// rest break ties — exactly as upstream.
    private static func bestFormat(
        for device: AVCaptureDevice,
        targetWidth: Int64,
        targetHeight: Int64,
        targetFps: Int64
    ) -> AVCaptureDevice.Format? {
        // Orientation-independent target (long/short edges).
        let targetLong = Double(max(targetWidth, targetHeight))
        let targetShort = Double(max(1, min(targetWidth, targetHeight)))
        let targetAspect = targetLong / targetShort
        let targetPixels = max(1, targetLong * targetShort)
        let desiredFps = Double(targetFps)

        // weight = (N - index) for constraints in priority order [res, fps, af, hdr, photoQ].
        let wRes = 5.0, wFps = 4.0, wAf = 3.0, wHdr = 2.0, wPhoto = 1.0

        func penalty(_ f: AVCaptureDevice.Format) -> Double {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let long = Double(max(dims.width, dims.height))
            let short = Double(max(1, min(dims.width, dims.height)))

            // Resolution: aspect (100× past 2% tolerance) + log-pixel distance.
            let aspectDiff = abs((long / short) - targetAspect) / targetAspect
            let aspectPenalty = aspectDiff < 0.02 ? 0.0 : 100.0 * aspectDiff
            let logPixel = abs(log((long * short) / targetPixels))
            var total = (aspectPenalty + logPixel) * wRes

            // FPS: 0 if inside a supported range, else nearest-range distance.
            if desiredFps > 0 {
                let fpsPenalty = f.videoSupportedFrameRateRanges.map { r -> Double in
                    if desiredFps >= r.minFrameRate && desiredFps <= r.maxFrameRate { return 0 }
                    return max(r.minFrameRate - desiredFps, desiredFps - r.maxFrameRate)
                }.min() ?? 1000
                total += fpsPenalty * wFps
            }

            // Phase-detection autofocus preference.
            if #available(iOS 13.0, *) {
                total += (f.autoFocusSystem == .phaseDetection ? 0.0 : 1.0) * wAf
            }
            // Prefer HDR-capable + high-quality-photo formats (so later toggles work).
            total += (f.isVideoHDRSupported ? 0.0 : 1.0) * wHdr
            if #available(iOS 15.0, *) {
                total += (f.isHighPhotoQualitySupported ? 0.0 : 1.0) * wPhoto
            }
            return total
        }

        return device.formats.min(by: { penalty($0) < penalty($1) })
    }
}

enum NitraCameraError: Error {
    case configurationFailed
    case captureFailed
    case deviceNotFound
    case permissionDenied
}
