import AVFoundation
import VideoToolbox

/// Hardware H.264 encoder fed through `NitroCameraOutputs`: a
/// VTCompressionSession sized from the session's first frame. Counts the
/// encoded frames (`stats`); a publisher plugin would ship them instead.
final class EncodedOutput {
    private let textureId: Int64
    private let bitRate: Int64
    private static let sinkId = "nitro_camera.encodedOutput"
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var stopped = false
    private var frames: Int64 = 0, keyframes: Int64 = 0, bytes: Int64 = 0
    private var firstPtsUs: Int64 = -1, lastPtsUs: Int64 = -1

    init(textureId: Int64, bitRate: Int64) {
        self.textureId = textureId
        self.bitRate = bitRate
        NitroCameraOutputs.add(textureId: textureId, id: Self.sinkId) { [weak self] in self?.encode($0) }
    }

    // Frame queue.
    private func encode(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lock.lock(); defer { lock.unlock() }
        if stopped { return }
        if session == nil {
            var s: VTCompressionSession?
            VTCompressionSessionCreate(
                allocator: nil, width: Int32(CVPixelBufferGetWidth(pb)),
                height: Int32(CVPixelBufferGetHeight(pb)), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            guard let s else { return }
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            session = s
        }
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, out in
            guard let self, status == noErr, let out, out.isValid else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: false)
                as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            let pts = Int64(CMSampleBufferGetPresentationTimeStamp(out).seconds * 1_000_000)
            self.lock.lock()
            self.frames += 1
            self.bytes += Int64(CMSampleBufferGetTotalSampleSize(out))
            if !notSync { self.keyframes += 1 }
            if self.firstPtsUs < 0 { self.firstPtsUs = pts }
            self.lastPtsUs = pts
            self.lock.unlock()
        }
    }

    func stats() -> EncodedOutputStats {
        lock.lock(); defer { lock.unlock() }
        return EncodedOutputStats(frames: frames, keyframes: keyframes, bytes: bytes,
                                  firstPtsUs: firstPtsUs, lastPtsUs: lastPtsUs)
    }

    func stop() {
        NitroCameraOutputs.remove(textureId: textureId, id: Self.sinkId)
        lock.lock()
        stopped = true
        let s = session
        session = nil
        lock.unlock()
        if let s { VTCompressionSessionInvalidate(s) }
    }
}
