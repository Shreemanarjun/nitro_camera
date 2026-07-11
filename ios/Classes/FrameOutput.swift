import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import CoreImage
import Metal
import Flutter

/// Video-data-output plumbing for one camera session: publishes frames to the
/// Flutter texture (GPU path), emits CPU frames into the Nitro FFI stream,
/// dispatches native ML detectors, feeds the recorder, and surfaces didDrop
/// diagnostics.
///
/// vision-camera analogue: ios/Hybrid Objects/Outputs/HybridCameraVideoFrameOutput.swift
/// (their sample-buffer callbacks live in Delegates/FrameDelegate.swift and
/// Delegates/AudioFrameDelegate.swift; here both land on this one object and
/// audio is routed straight to the VideoRecorder).
final class FrameOutput: NSObject, FlutterTexture,
                         AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {

    /// The AVFoundation output this object wraps (upstream's `output`).
    let output = AVCaptureVideoDataOutput()

    /// Flutter texture id. The FlutterTexture registered with the registry is
    /// THIS object; the owning CameraSession forwards this id as its own.
    var textureId: Int64 = 0

    private let device: AVCaptureDevice
    private let frameQueue: DispatchQueue
    private weak var textureRegistry: FlutterTextureRegistry?

    /// Recording sink — video/audio samples are forwarded on `frameQueue`
    /// (vision-camera's RecorderDelegate hook on their video output).
    var recorder: VideoRecorder?
    /// The session's audio-data output (identity check in captureOutput).
    var audioOutput: AVCaptureAudioDataOutput?

    // Latest camera frame (GPU path → Flutter Texture)
    private var latestPixelBuffer: CVPixelBuffer?
    private let pixelLock = NSLock()
    // Latched true in teardown() (under pixelLock). Once set, captureOutput must
    // NOT call textureFrameAvailable — the texture is about to be unregistered,
    // and signalling a freed texture crashes FlutterEngine (EXC_BAD_ACCESS).
    private var closed = false

    // CPU path — ONE reused frame buffer (never per-frame allocate; that leaks
    // the whole camera stream. Mirrors the Android `directBuffer`. Freed in deinit.)
    private var frameBuffer: UnsafeMutablePointer<UInt8>?
    private var frameBufferCapacity: Int = 0

    // Frame processing (CPU path → Nitro stream)
    var frameProcessingEnabled = false
    var onFrame: ((CameraFrame) -> Void)?
    /// Event hook: (CameraEventType index, message) — wired to the session's hub.
    var onEvent: ((Int64, String) -> Void)?

    // Native ML detector ("barcode" / "face"; "" = off). Written on `frameQueue`
    // (via setNativeDetector) and read in captureOutput on the same queue.
    private var nativeDetector: String = ""

    // One-shot "first frame delivered" log per start() — the cheapest way to
    // prove on-device whether a chosen format actually streams (4K debugging).
    // Reset by CameraSession.start().
    var firstFrameLogged = false
    // Monotonic video-frame counter — CameraSession's runtime-error debounce
    // compares it across a grace window to tell a TRANSIENT error (stream
    // recovered; e.g. the spurious -11800 burst right after a 4K session
    // start) from a dead session that must surface an error event.
    private(set) var frameActivityCounter: Int64 = 0
    // Dropped-frame counter for the rate-limited didDrop diagnostics
    // (vision-camera's onFrameDropped). Touched on `frameQueue` only.
    private var droppedFrameCounter: Int64 = 0

    // Modernized properties for per-frame analysis
    var samplingRate: Int64 = 1
    var pixelFormat: Int64 = 1 // 0: YUV/Luma, 1: BGRA

    /// Active GLSL preview/video filter (Android parity). When set AND the
    /// stream is BGRA (i.e. NOT scanner/YUV mode), the preview texture and the
    /// recorded video are rendered through the matching Core Image filter so the
    /// live preview + video match the filtered photo. Every path falls back to
    /// the raw buffer on failure, so preview/recording can never break.
    private var filterShader: String = ""
    /// Thread-safe setter: written from the FFI thread, read on the frame queue.
    func setPreviewFilterShader(_ shader: String) {
        pixelLock.lock(); filterShader = shader; pixelLock.unlock()
    }
    // GPU-backed so the per-frame preview render is fast enough (a CPU CIContext
    // starves the frame queue → the texture looks unfiltered / frozen).
    private let filterContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private var filterPool: CVPixelBufferPool?
    private var filterPoolW = 0
    private var filterPoolH = 0

    /// Renders [src] through the current filter into a pooled BGRA buffer, or nil
    /// if there's no filter / it fails (caller then uses the raw buffer).
    private func renderFilter(_ src: CVPixelBuffer, shader: String) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if filterPool == nil || filterPoolW != w || filterPoolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            filterPool = pool; filterPoolW = w; filterPoolH = h
        }
        guard let pool = filterPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let outBuf = out,
              let filtered = PhotoOutput.filteredImage(CIImage(cvPixelBuffer: src), shader: shader)
        else { return nil }
        // Render into DeviceRGB (sRGB) — the SAME space the working photo path
        // uses (jpegRepresentation). A Metal-backed CIContext queues render work
        // and returns BEFORE the buffer is written, so a plain render(to:) can
        // hand a half-rendered frame to the recorder (visible as flicker/partial
        // frames). Use CIRenderDestination + waitUntilCompleted to force GPU
        // completion, so the appended frame is always fully filtered.
        let dest = CIRenderDestination(pixelBuffer: outBuf)
        dest.colorSpace = CGColorSpaceCreateDeviceRGB()
        do {
            try filterContext.startTask(toRender: filtered, from: filtered.extent,
                                        to: dest, at: .zero).waitUntilCompleted()
        } catch {
            filterContext.render(filtered, to: outBuf, bounds: filtered.extent,
                                 colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        // Carry the camera buffer's colour attachments so the recorder muxes the
        // filtered frame with the same colour handling as the raw stream.
        CVBufferPropagateAttachments(src, outBuf)
        return outBuf
    }

    /// Wraps a filtered pixel buffer in a CMSampleBuffer that carries [original]'s
    /// timing, so the recorder can append the filtered frame. nil on failure
    /// (caller then records the raw sample buffer — unfiltered but never broken).
    private func wrapSampleBuffer(_ pb: CVPixelBuffer, like original: CMSampleBuffer) -> CMSampleBuffer? {
        var fmt: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr,
              let format = fmt else { return nil }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(original, at: 0, timingInfoOut: &timing)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pb,
                formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
    private var frameCounter: Int64 = 0

    init(device: AVCaptureDevice,
         frameQueue: DispatchQueue,
         textureRegistry: FlutterTextureRegistry) {
        self.device = device
        self.frameQueue = frameQueue
        self.textureRegistry = textureRegistry
        super.init()
    }

    deinit {
        frameBuffer?.deallocate()
    }

    // MARK: - Configuration hooks

    func setSamplingRate(_ rate: Int64) {
        self.samplingRate = max(1, rate)
    }

    /// Activates a native ML detector ("barcode" / "face"; "" = off). Results
    /// are emitted as `detection` events (JSON payload in `message`). Unlike
    /// Android, no capture-graph change is needed: the video data output
    /// already delivers every frame.
    func setNativeDetector(_ name: String) {
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            if name != self.nativeDetector {
                // Off or swapped — drop the old per-texture state promptly (the
                // runner also recycles on swap, this just frees it eagerly).
                NitraDetectors.stop(textureId: self.textureId)
            }
            self.nativeDetector = name
        }
    }

    /// Detaches the sample-buffer delegates and releases held buffers/detector
    /// state so a closed session's capture pool can be torn down (otherwise a
    /// reopened session leaks its predecessor's buffers + pool). Called from
    /// CameraSession.close().
    func teardown() {
        output.setSampleBufferDelegate(nil, queue: nil)
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        onFrame = nil
        frameProcessingEnabled = false
        // Release any native-detector state (delegate is already detached, so
        // no further captureOutput can race this).
        nativeDetector = ""
        NitraDetectors.stop(textureId: textureId)
        pixelLock.lock()
        closed = true
        latestPixelBuffer = nil
        pixelLock.unlock()
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
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameActivityCounter &+= 1
        if !firstFrameLogged {
            firstFrameLogged = true
            NSLog("NitroCamera stream: first frame %ldx%ld",
                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        }

        // Shader filtering. The LIVE PREVIEW is filtered on the Flutter layer
        // (the example's FilteredPreview / ColorFiltered) — filtering the texture
        // NATIVELY too would apply the filter TWICE and cancel it out (INVERT of
        // an inverted frame is the original: exactly the "photo inverts, preview
        // doesn't" bug). So the texture always shows the RAW frame; the native
        // filter is applied only to the RECORDED video, which the Flutter layer
        // can't reach. Only render while actually recording (GPU per-frame cost),
        // and only in BGRA mode — scanner/YUV needs the raw luma plane. Any
        // failure falls back to raw, so this can't break preview or recording.
        pixelLock.lock()
        if closed { pixelLock.unlock(); return }
        let shader = filterShader
        pixelLock.unlock()
        let filteredForRecording: CVPixelBuffer? =
            (recorder?.isRecordingActive == true && !shader.isEmpty && pixelFormat == 1)
                ? renderFilter(pixelBuffer, shader: shader) : nil

        // GPU path — the texture shows the RAW frame (Flutter filters the preview).
        pixelLock.lock()
        if closed { pixelLock.unlock(); return }
        latestPixelBuffer = pixelBuffer
        let reg = textureRegistry
        pixelLock.unlock()
        reg?.textureFrameAvailable(textureId)

        // Recording path — feed the AVAssetWriter (runs on this same frameQueue).
        // Record the natively-FILTERED frame (wrapped with the original timing)
        // when a filter is active; otherwise the raw sample buffer.
        if let fb = filteredForRecording, let sb = wrapSampleBuffer(fb, like: sampleBuffer) {
            recorder?.appendVideo(sb)
        } else {
            recorder?.appendVideo(sampleBuffer)
        }

        // Native ML detector path (Vision) — throttled + drop-while-busy inside
        // the runner. Runs even when frame processing is off (the Android
        // analogue adds the frame-reader target for detectors; here the video
        // data output already delivers every frame).
        if !nativeDetector.isEmpty {
            NitraDetectors.process(
                pixelBuffer: pixelBuffer,
                textureId: textureId,
                detector: nativeDetector
            ) { [weak self] json in
                guard let self = self else { return }
                self.onEvent?(12 /* detection */, json)
            }
        }

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

    // Dropped-frame diagnostics (vision-camera's onFrameDropped) — surfaced
    // rate-limited (1 in 30) so a sustained pipeline stall is visible in the
    // event stream without flooding it. Runs on `frameQueue`.
    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        droppedFrameCounter &+= 1
        guard droppedFrameCounter % 30 == 1 else { return }
        let reason = (CMGetAttachment(sampleBuffer,
                                      key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                      attachmentModeOut: nil) as? String) ?? "unknown"
        NSLog("NitroCamera stream: %lld frames dropped so far (reason: %@)",
              droppedFrameCounter, reason)
        onEvent?(5 /* frameDropped */, reason)
    }
}
