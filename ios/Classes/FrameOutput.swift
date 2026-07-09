import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
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

        // GPU path — update Flutter texture
        pixelLock.lock()
        latestPixelBuffer = pixelBuffer
        pixelLock.unlock()
        textureRegistry?.textureFrameAvailable(textureId)

        // Recording path — feed the AVAssetWriter (runs on this same frameQueue).
        recorder?.appendVideo(sampleBuffer)

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
