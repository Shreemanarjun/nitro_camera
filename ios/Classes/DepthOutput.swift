import AVFoundation

/// AVCaptureDepthDataOutput → float32 metres for `DepthFrame`
/// (vision-camera's CameraDepthFrameOutput). Depth is converted to
/// DepthFloat32 and copied into one reused buffer that the Dart listener
/// borrows. Portrait-oriented and mirrored like the video frames.
final class DepthOutput: NSObject, AVCaptureDepthDataOutputDelegate {
    let output = AVCaptureDepthDataOutput()
    private let textureId: Int64
    private let queue = DispatchQueue(label: "dev.shreeman.nitro_camera.depth", qos: .userInitiated)
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var capacity = 0
    var onFrame: ((DepthFrame) -> Void)?

    init(textureId: Int64) {
        self.textureId = textureId
        super.init()
        output.isFilteringEnabled = true
        output.alwaysDiscardsLateDepthData = true
        output.setDelegate(self, callbackQueue: queue)
    }

    /// The device's active format must carry depth formats; picks a float32
    /// depth (or disparity) format. Returns false when there is none.
    static func selectDepthFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.activeFormat.supportedDepthDataFormats
        let float = formats.filter {
            let t = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return t == kCVPixelFormatType_DepthFloat32 || t == kCVPixelFormatType_DisparityFloat32
        }
        return (float.isEmpty ? formats : float).max {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        handle(depthData, timestamp: timestamp)
    }

    /// Converts and emits one depth map (also called by SyncOutput, whose
    /// synchronizer replaces this output's own delegate callbacks).
    func handle(_ depthData: AVDepthData, timestamp: CMTime) {
        guard let dims = Self.copyMetres(depthData, into: &buffer, capacity: &capacity),
              let dst = buffer else { return }
        onFrame?(DepthFrame(data: dst, size: Int64(dims.w * 4 * dims.h), width: Int64(dims.w), height: Int64(dims.h),
                            bytesPerRow: Int64(dims.w * 4),
                            timestamp: Int64(CMTimeGetSeconds(timestamp) * 1000),
                            textureId: textureId))
    }

    /// Copies [depthData] as packed float32 metres into a grow-only buffer.
    /// Returns the map size, or nil when it can't be read.
    static func copyMetres(_ depthData: AVDepthData,
                           into buffer: inout UnsafeMutablePointer<UInt8>?,
                           capacity: inout Int) -> (w: Int, h: Int)? {
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let n = w * 4 * h
        if buffer == nil || capacity < n {
            retireBorrowed(buffer)
            buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            capacity = n
        }
        guard let dst = buffer else { return nil }
        for y in 0..<h { memcpy(dst + y * w * 4, base + y * rowBytes, w * 4) }
        return (w, h)
    }

    /// Restores this output's own delegate after a synchronizer released it.
    func reattach() {
        output.setDelegate(self, callbackQueue: queue)
    }

    /// Detaches the delegate and drains in-flight callbacks before the buffer goes.
    func teardown() {
        output.setDelegate(nil, callbackQueue: nil)
        queue.sync {}
        onFrame = nil
        retireBorrowed(buffer)
        buffer = nil
    }
}
