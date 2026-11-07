import AVFoundation

/// Pairs each video frame with the depth map captured with it
/// (vision-camera's CameraOutputSynchronizer) using
/// AVCaptureDataOutputSynchronizer. The synchronizer takes over both
/// outputs' callbacks, so every frame and depth map is fed back into
/// FrameOutput / DepthOutput here — preview, recording and the plain frame
/// and depth streams keep working — and matched pairs are copied into this
/// output's own buffers for `syncedStream`.
final class SyncOutput: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    private let synchronizer: AVCaptureDataOutputSynchronizer
    private let frameOutput: FrameOutput
    private let depthOutput: DepthOutput
    private let queue: DispatchQueue
    var onSynced: ((SyncedFrame) -> Void)?

    // Grow-only borrows handed to Dart, separate from the plain streams'
    // buffers so neither stream overwrites the other's frame.
    private var pixels: UnsafeMutablePointer<UInt8>?
    private var pixelsCapacity = 0
    private var depth: UnsafeMutablePointer<UInt8>?
    private var depthCapacity = 0

    init(frameOutput: FrameOutput, depthOutput: DepthOutput, queue: DispatchQueue) {
        self.frameOutput = frameOutput
        self.depthOutput = depthOutput
        self.queue = queue
        synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [frameOutput.output, depthOutput.output])
        super.init()
        synchronizer.setDelegate(self, queue: queue)
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        let video = collection.synchronizedData(for: frameOutput.output) as? AVCaptureSynchronizedSampleBufferData
        let depthData = collection.synchronizedData(for: depthOutput.output) as? AVCaptureSynchronizedDepthData

        // Keep the regular paths fed (the synchronizer replaced their delegates).
        if let v = video, !v.sampleBufferWasDropped,
           let connection = frameOutput.output.connection(with: .video) {
            frameOutput.captureOutput(frameOutput.output, didOutput: v.sampleBuffer, from: connection)
        }
        if let d = depthData, !d.depthDataWasDropped {
            depthOutput.handle(d.depthData, timestamp: d.timestamp)
        }

        guard let emit = onSynced,
              let v = video, !v.sampleBufferWasDropped,
              let d = depthData, !d.depthDataWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(v.sampleBuffer),
              let dims = DepthOutput.copyMetres(d.depthData, into: &depth, capacity: &depthCapacity),
              let depthPtr = depth else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
                                : CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let n = rowBytes * h
        if pixels == nil || pixelsCapacity < n {
            retireBorrowed(pixels)
            pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            pixelsCapacity = n
        }
        guard let dst = pixels else { return }
        memcpy(dst, base, n)

        emit(SyncedFrame(
            pixels: dst, size: Int64(n), width: Int64(w), height: Int64(h),
            bytesPerRow: Int64(rowBytes), pixelFormat: frameOutput.pixelFormat,
            isMirrored: frameOutput.isFrontCamera ? 1 : 0,
            depth: depthPtr, depthSize: Int64(dims.w * 4 * dims.h),
            depthWidth: Int64(dims.w), depthHeight: Int64(dims.h), depthBytesPerRow: Int64(dims.w * 4),
            timestamp: Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(v.sampleBuffer)) * 1000),
            textureId: frameOutput.textureId))
    }

    /// Stops pairing and hands both outputs back their own delegates.
    func teardown() {
        synchronizer.setDelegate(nil, queue: nil)
        queue.sync {}
        onSynced = nil
        frameOutput.output.setSampleBufferDelegate(frameOutput, queue: queue)
        depthOutput.reattach()
        retireBorrowed(pixels); pixels = nil
        retireBorrowed(depth); depth = nil
    }
}
