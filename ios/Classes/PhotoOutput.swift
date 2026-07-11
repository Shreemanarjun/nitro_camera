import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Photo capture for one camera session: settings construction, capture
/// delegate lifecycle (continuation + stuck-capture watchdog), fast preview
/// thumbnails, GPS EXIF injection, and DNG/ProRAW capture.
///
/// vision-camera analogue: ios/Hybrid Objects/Outputs/HybridCameraPhotoOutput.swift
/// (their capture-callback lifecycle lives in Delegates/CapturePhotoDelegate.swift;
/// here the delegate is this object itself).
final class PhotoOutput: NSObject, AVCapturePhotoCaptureDelegate {

    /// The AVFoundation output this object wraps (upstream's `output`).
    let output = AVCapturePhotoOutput()

    private let device: AVCaptureDevice
    private let session: AVCaptureSession
    private let sessionQueue: DispatchQueue
    /// Event hook: (CameraEventType index, message) — wired to the session's hub.
    var onEvent: ((Int64, String) -> Void)?

    // Photo capture continuations
    private var photoContinuation: CheckedContinuation<PhotoResult, Error>?
    // Monotonic capture id — lets the stuck-capture watchdog verify that the
    // pending continuation still belongs to *its* capture before failing it.
    private var photoCaptureSeq: UInt64 = 0
    // AVCapturePhotoSettings.uniqueID of the in-flight capture — lets the
    // didFinishCaptureFor error path verify the callback belongs to the
    // CURRENT capture (a late error from capture N must not steal capture
    // N+1's continuation). Written under `captureLock`.
    private var photoCaptureSettingsId: Int64 = -1
    // Capture phase timestamps for the "photo: precapture/capture/write" log
    // (Android parity). Written under `captureLock` / read in the delegate.
    private var photoCaptureStart: CFAbsoluteTime = 0
    private var photoShutterTime: CFAbsoluteTime = 0

    // Serialises access to the capture continuation so it is never leaked
    // (set-but-never-resumed) or double-resumed (which is fatal) when a
    // stop / delegate / teardown race.
    private let captureLock = NSLock()

    // Session-stored flash mode (Android parity: `setFlash` stores, capture
    // applies). Plain `takePhoto()` (and `takeSnapshot`) honor this; a per-shot
    // `PhotoOptions.flash` overrides it.
    private var storedFlashMode: AVCaptureDevice.FlashMode = .off

    // Pending GPS geotag for the next photo (EXIF injection in the delegate).
    private var pendingPhotoLocation: (lat: Double, lon: Double, alt: Double)?
    private let ciContext = CIContext()

    /// Active GLSL preview filter from `setFilterShader` (Android parity). iOS
    /// previously ignored it entirely, so a filtered photo SAVED unfiltered.
    /// When set, captured stills are rendered through the matching Core Image
    /// filter (the app's shaders are simple colour ops that map to built-ins).
    var filterShader: String = ""

    /// Maps one of the example app's GLSL colour shaders to a Core Image filter.
    /// Returns nil for shaders we don't recognise (unfiltered — same as before),
    /// so this never makes a capture worse. Full arbitrary-GLSL support would
    /// need a GL/Metal pass; these built-ins cover the shipped filter set.
    static func filteredImage(_ input: CIImage, shader: String) -> CIImage? {
        let s = shader
        if s.contains("1.0 - c.rgb") { // INVERT
            // Invert via CIColorControls with contrast -1: output =
            // (input - 0.5) * -1 + 0.5 = 1 - input. CIColorInvert and CIColorMatrix
            // render UNCHANGED through CIContext.render(to:) on the camera buffer
            // (the preview path), but CIColorControls survives it — it's the SAME
            // filter GRAYSCALE uses, which is confirmed working in the preview.
            let f = CIFilter.colorControls(); f.inputImage = input; f.contrast = -1.0
            return f.outputImage
        }
        if s.contains("vec3(luma)") && s.contains("0.299") { // GRAYSCALE
            let f = CIFilter.colorControls(); f.inputImage = input; f.saturation = 0; return f.outputImage
        }
        if s.contains("0.393, 0.769") { // SEPIA
            let f = CIFilter.sepiaTone(); f.inputImage = input; f.intensity = 1.0; return f.outputImage
        }
        if s.contains("smoothstep(0.8, 0.3") { // VIGNETTE
            let f = CIFilter.vignette(); f.inputImage = input; f.intensity = 2.0; f.radius = 2.0; return f.outputImage
        }
        if s.contains("pink") { // CYBERPUNK: luma → blue↔pink gradient
            let mono = CIFilter.photoEffectMono(); mono.inputImage = input
            let fc = CIFilter.falseColor(); fc.inputImage = mono.outputImage
            fc.color0 = CIColor(red: 0, green: 1, blue: 1)
            fc.color1 = CIColor(red: 1, green: 0, blue: 1)
            return fc.outputImage
        }
        return nil
    }

    /// Renders [jpegData] through the [shader]'s Core Image filter and RE-ATTACHES
    /// the source EXIF orientation, so a filtered still orients EXACTLY like the
    /// unfiltered capture. We decode with CGImageSourceCreateImageAtIndex (which
    /// does NOT auto-apply orientation) and pass RAW pixels through the filter,
    /// then write the output with the original orientation tag — never baking
    /// rotation into pixels (that double-rotated). Returns nil if the shader
    /// isn't recognised or decoding fails — capture then saves the raw JPEG.
    static func applyFilter(to jpegData: Data, shader: String, ciContext: CIContext) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[
            kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard let filtered = filteredImage(CIImage(cgImage: cg), shader: shader),
              let outCG = ciContext.createCGImage(filtered, from: filtered.extent) else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                outData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            dest, outCG, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }

    init(device: AVCaptureDevice,
         session: AVCaptureSession,
         sessionQueue: DispatchQueue) {
        self.device = device
        self.session = session
        self.sessionQueue = sessionQueue
        super.init()
    }

    // MARK: - Session-graph hooks (called by CameraSession)

    /// Adds + configures the output on [session]. Must run inside the owning
    /// session's begin/commitConfiguration block.
    func configure(in session: AVCaptureSession) {
        if session.canAddOutput(output) { session.addOutput(output) }
        output.isHighResolutionCaptureEnabled = true
        // Opt in to the full quality range so per-shot settings can request up to
        // `.quality` (requesting above the output's max throws at capture time).
        if #available(iOS 13.0, *) {
            output.maxPhotoQualityPrioritization = .quality
        }
    }

    /// Pre-warms the photo pipeline for a default capture (vision-camera's
    /// prepareDefaultPhotoSettings): the output allocates its capture
    /// resources up front instead of on the FIRST takePhoto. Must run after
    /// the output has been added to the session (post commitConfiguration);
    /// preparation completes lazily once the session starts.
    func prewarm() {
        output.setPreparedPhotoSettingsArray([AVCapturePhotoSettings()],
                                             completionHandler: nil)
    }

    func setFlash(mode: Int64) {
        // Flash is per-shot on iOS — store it and apply at capture time
        // (previously this was a no-op, so `setFlash` was silently ignored and
        // plain `takePhoto()` hard-coded `.auto`, firing a slow flash
        // precapture sequence in low light even with flash OFF in the UI).
        switch mode {
        case 1:  storedFlashMode = .on
        case 2:  storedFlashMode = .auto
        default: storedFlashMode = .off
        }
    }

    /// Resolves any in-flight capture continuation so its awaiting task
    /// doesn't hang forever when the session is torn down mid-capture.
    /// Called from CameraSession.close().
    func cancelPending() {
        captureLock.lock()
        let pc = photoContinuation; photoContinuation = nil
        captureLock.unlock()
        pc?.resume(throwing: CameraError.captureFailed)
    }

    // MARK: - Photo capture

    func takePhoto(flashMode: AVCaptureDevice.FlashMode? = nil,
                   quality: Int64 = 1,
                   redEyeReduction: Bool = false,
                   location: (lat: Double, lon: Double, alt: Double)? = nil) async throws -> PhotoResult {
        let settings = AVCapturePhotoSettings()
        // nil = "no per-shot override" → the session-stored mode (setFlash).
        // Only request modes the OUTPUT supports for the current format —
        // an unsupported settings.flashMode raises an uncatchable NSException.
        let wantedFlash = flashMode ?? storedFlashMode
        settings.flashMode = (device.hasFlash &&
                              output.supportedFlashModes.contains(wantedFlash))
            ? wantedFlash : .off

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
                             output.maxPhotoQualityPrioritization.rawValue)
            settings.photoQualityPrioritization =
                AVCapturePhotoOutput.QualityPrioritization(rawValue: capped) ?? .balanced
        }
        if redEyeReduction, output.isAutoRedEyeReductionSupported {
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
        return try await capture(with: settings)
    }

    /// Shared photo-capture core: registers the continuation (fail-fast when a
    /// capture is already in flight — the old code silently OVERWROTE the
    /// pending continuation, leaking it so the first caller hung forever),
    /// dispatches `capturePhoto` on the SESSION queue (serialised with
    /// start/stop/reconfigure so a capture can never race a session rebuild),
    /// and arms a watchdog that converts a wedged capture into an error
    /// instead of an eternal hang.
    private func capture(with settings: AVCapturePhotoSettings) async throws -> PhotoResult {
        return try await withCheckedThrowingContinuation { continuation in
            captureLock.lock()
            guard photoContinuation == nil else {
                captureLock.unlock()
                continuation.resume(throwing: CameraError.captureInProgress)
                return
            }
            photoContinuation = continuation
            photoCaptureSeq &+= 1
            let seq = photoCaptureSeq
            photoCaptureSettingsId = settings.uniqueID
            photoCaptureStart = CFAbsoluteTimeGetCurrent()
            photoShutterTime = 0
            captureLock.unlock()

            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                guard self.session.isRunning else {
                    self.takePhotoContinuation(seq: seq)?
                        .resume(throwing: CameraError.sessionNotRunning)
                    return
                }
                self.output.capturePhoto(with: settings, delegate: self)
            }

            // Watchdog: flash + Deep Fusion worst case is a few seconds; 20s
            // of silence from the delegate means the capture is wedged.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self = self,
                      let cont = self.takePhotoContinuation(seq: seq) else { return }
                NSLog("NitroCamera photo: WATCHDOG — no delegate callback after 20s, failing capture #%llu", seq)
                cont.resume(throwing: CameraError.captureTimedOut)
            }
        }
    }

    /// Atomically takes the pending photo continuation. When [seq] is given,
    /// only takes it if it still belongs to that capture (watchdog / stale
    /// error paths must not steal a NEWER capture's continuation).
    @discardableResult
    private func takePhotoContinuation(seq: UInt64? = nil) -> CheckedContinuation<PhotoResult, Error>? {
        captureLock.lock(); defer { captureLock.unlock() }
        if let seq = seq, seq != photoCaptureSeq { return nil }
        let c = photoContinuation; photoContinuation = nil; return c
    }

    // MARK: - RAW (DNG) capture — PhotoOptions.outputFormat == 1

    /// RAW (DNG) still capture.
    ///
    /// Prefers Apple ProRAW (iOS 14.3+) when the photo output supports it, else
    /// falls back to the sensor's Bayer DNG format. Throws `rawNotSupported`
    /// with a clear message when the current output offers no RAW pixel formats
    /// (simulator, front cameras, virtual devices, some active formats).
    ///
    /// `skipMetadata == 1` drops the GPS geotag — the only optional metadata we
    /// attach (the DNG's intrinsic EXIF cannot be stripped without re-encoding).
    /// `enableShutterSound` is a no-op on iOS: the system plays the shutter
    /// sound itself where required and offers no public mute on
    /// AVCapturePhotoOutput (we deliberately do NOT hack audio sessions).
    func takeDngPhoto(options: PhotoOptions) async throws -> PhotoResult {
        // ProRAW must be enabled on the OUTPUT before building per-shot
        // settings — only then do ProRAW pixel formats appear in the list.
        // Enable it ONCE: flipping the flag rebuilds the photo pipeline
        // (hundreds of ms), so re-setting it per shot made every DNG slow.
        if #available(iOS 14.3, *), output.isAppleProRAWSupported,
           !output.isAppleProRAWEnabled {
            output.isAppleProRAWEnabled = true
        }
        let rawFormats = output.availableRawPhotoPixelFormatTypes
        guard var rawFormat = rawFormats.first else {
            throw CameraError.rawNotSupported
        }
        if #available(iOS 14.3, *),
           let proRaw = rawFormats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            rawFormat = proRaw
        }

        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: nil)
        // Flash + RAW only combine on some devices; honor the request when the
        // output supports the mode (settings.flashMode throws otherwise).
        let requestedFlash: AVCaptureDevice.FlashMode
        switch options.flash {
        case 1:  requestedFlash = .on
        case 2:  requestedFlash = .auto
        default: requestedFlash = .off
        }
        if device.hasFlash, output.supportedFlashModes.contains(requestedFlash) {
            settings.flashMode = requestedFlash
        }
        // GPS geotag → photo metadata (embedded into the DNG by the output),
        // skipped entirely when skipMetadata is set.
        if options.hasLocation != 0, options.skipMetadata == 0 {
            settings.metadata = [
                kCGImagePropertyGPSDictionary as String: [
                    kCGImagePropertyGPSLatitude as String:     abs(options.latitude),
                    kCGImagePropertyGPSLatitudeRef as String:  options.latitude >= 0 ? "N" : "S",
                    kCGImagePropertyGPSLongitude as String:    abs(options.longitude),
                    kCGImagePropertyGPSLongitudeRef as String: options.longitude >= 0 ? "E" : "W",
                    kCGImagePropertyGPSAltitude as String:     abs(options.altitude),
                    kCGImagePropertyGPSAltitudeRef as String:  options.altitude >= 0 ? 0 : 1,
                ],
            ]
        }

        return try await capture(with: settings)
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    // Shutter-timing callbacks → events (vision-camera onWill{Begin,Capture}Photo).
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onEvent?(6 /* photoCaptureBegan */, "")
    }
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        captureLock.lock()
        photoShutterTime = CFAbsoluteTimeGetCurrent()
        captureLock.unlock()
        onEvent?(7 /* photoCaptureShutter */, "")
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        let processedAt = CFAbsoluteTimeGetCurrent()
        captureLock.lock()
        let maybeCont = photoContinuation
        photoContinuation = nil
        let t0 = photoCaptureStart
        let tShutter = photoShutterTime
        captureLock.unlock()
        // Android-parity timing: precapture (request → shutter, AE/flash
        // convergence) + capture (shutter → processed frame). `write` logs below
        // once the file is on disk.
        let precaptureMs = tShutter > 0 ? Int((tShutter - t0) * 1000) : -1
        let captureMs = Int((processedAt - max(tShutter, t0)) * 1000)
        let location = pendingPhotoLocation
        pendingPhotoLocation = nil

        // RAW (DNG) capture — write the file data straight out (no EXIF
        // re-encode / thumbnail pass; the GPS geotag was already attached via
        // `AVCapturePhotoSettings.metadata` in takeDngPhoto).
        if photo.isRawPhoto {
            guard let cont = maybeCont else { return }
            if let error = error { cont.resume(throwing: error); return }
            guard let data = photo.fileDataRepresentation() else {
                cont.resume(throwing: CameraError.captureFailed); return
            }
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let url = cachesDir.appendingPathComponent(
                "cap_\(Int64(Date().timeIntervalSince1970 * 1000)).dng")
            do {
                try data.write(to: url)
                var dims = photo.resolvedSettings.rawPhotoDimensions
                if dims.width == 0 || dims.height == 0 {
                    dims = photo.resolvedSettings.photoDimensions
                }
                NSLog("NitroCamera photo(DNG): precapture=%dms capture=%dms write=%dms",
                      precaptureMs, captureMs,
                      Int((CFAbsoluteTimeGetCurrent() - processedAt) * 1000))
                cont.resume(returning: PhotoResult(
                    path: url.path,
                    width: Int64(dims.width),
                    height: Int64(dims.height),
                    fileSize: Int64(data.count),
                    orientation: Int64(device.position == .front ? 0 : 90),
                    isMirrored: device.position == .front ? 1 : 0,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                ))
            } catch {
                cont.resume(throwing: error)
            }
            return
        }

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
            cont.resume(throwing: CameraError.captureFailed); return
        }
        // Bake the active GLSL filter into the saved still (iOS previously
        // ignored setFilterShader, so filtered photos saved unfiltered).
        // applyFilter re-attaches the source EXIF orientation, so orientation is
        // unchanged from the unfiltered path (device-based, below).
        var filteredRaw = raw
        if !filterShader.isEmpty,
           let filtered = Self.applyFilter(to: raw, shader: filterShader, ciContext: ciContext) {
            filteredRaw = filtered
        }
        // Inject GPS EXIF if a geotag was supplied (after filtering, which
        // re-encodes and would otherwise drop it).
        let data = location.flatMap {
            Self.jpegWithGPS(filteredRaw, lat: $0.lat, lon: $0.lon, alt: $0.alt)
        } ?? filteredRaw

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try data.write(to: tmp)
            let w = Int64(photo.resolvedSettings.photoDimensions.width)
            let h = Int64(photo.resolvedSettings.photoDimensions.height)
            NSLog("NitroCamera photo: precapture=%dms capture=%dms write=%dms",
                  precaptureMs, captureMs,
                  Int((CFAbsoluteTimeGetCurrent() - processedAt) * 1000))
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

    // vision-camera's CapturePhotoDelegate resolves errors here too: some
    // failures only surface at END of the capture sequence (processing either
    // never fired or fired without an error) — fail the still-pending
    // continuation now instead of leaving it to the 20s watchdog. A capture
    // that already resolved has no pending continuation, so this is a no-op.
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                            error: Error?) {
        captureLock.lock()
        let isCurrentCapture = resolvedSettings.uniqueID == photoCaptureSettingsId
        captureLock.unlock()
        guard isCurrentCapture, let error = error,
              let cont = takePhotoContinuation() else { return }
        NSLog("NitroCamera photo: didFinishCapture reported error: %@", error.localizedDescription)
        pendingPhotoLocation = nil
        cont.resume(throwing: error)
    }

    // MARK: - Helpers

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
}
