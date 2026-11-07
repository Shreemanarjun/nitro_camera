import CoreGraphics
import CoreImage
import CoreVideo

/// Scales every camera frame on the GPU into an ML-ready tensor
/// (vision-camera-resizer): Core Image on Metal does the crop / letterbox and
/// the resample into a small BGRA buffer, then one CPU pass at the tiny
/// output size lays it out as RGB(A) / BGR(A), uint8 or float32. Output is
/// upright and un-mirrored.
final class GpuResizer {
    private let context: CIContext
    private let lock = NSLock()
    private var options: ResizerOptions?
    var onResized: ((ResizedFrame) -> Void)?

    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var out: UnsafeMutablePointer<UInt8>?
    private var outCapacity = 0

    init(context: CIContext) { self.context = context }

    func configure(_ o: ResizerOptions) {
        lock.lock(); defer { lock.unlock() }
        options = o.enabled != 0 && o.width > 0 && o.height > 0 ? o : nil
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return options != nil
    }

    /// On the frame queue, once per frame while active.
    func process(_ pixelBuffer: CVPixelBuffer, timestamp: Int64, textureId: Int64, mirrored: Bool) {
        lock.lock()
        let opts = options
        lock.unlock()
        guard let o = opts, let emit = onResized else { return }
        let tw = Int(o.width), th = Int(o.height)
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard w > 0, h > 0 else { return }

        var img = CIImage(cvPixelBuffer: pixelBuffer)
        if mirrored {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
        }
        let sx = CGFloat(tw) / w, sy = CGFloat(th) / h
        let scale = o.scaleMode == 1 ? min(sx, sy) : max(sx, sy)
        img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        img = img.transformed(by: CGAffineTransform(translationX: (CGFloat(tw) - w * scale) / 2,
                                                    y: (CGFloat(th) - h * scale) / 2))
        let target = CGRect(x: 0, y: 0, width: tw, height: th)
        img = img.composited(over: CIImage(color: .black).cropped(to: target)).cropped(to: target)

        if pool == nil || poolW != tw || poolH != th {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: tw,
                kCVPixelBufferHeightKey as String: th,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolW = tw
            poolH = th
        }
        guard let pool = pool else { return }
        var scaled: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
        guard let small = scaled else { return }
        do {
            try context.startTask(toRender: img, from: target, to: CIRenderDestination(pixelBuffer: small), at: .zero)
                .waitUntilCompleted()
        } catch {
            return
        }

        let channels = Int(o.channels == 4 ? 4 : 3)
        let floatOut = o.dataType == 1
        let bytesPerValue = floatOut ? 4 : 1
        let n = tw * th * channels * bytesPerValue
        if out == nil || outCapacity < n {
            retireBorrowed(out)
            out = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            outCapacity = n
        }
        guard let dst = out else { return }
        CVPixelBufferLockBaseAddress(small, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(small, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(small)?.assumingMemoryBound(to: UInt8.self) else { return }
        let row = CVPixelBufferGetBytesPerRow(small)
        GpuResizer.layout(bgra: base, rowBytes: row, width: tw, height: th,
                          channels: channels, bgr: o.channelOrder == 1, float32: floatOut, into: dst)
        emit(ResizedFrame(data: dst, size: Int64(n), width: Int64(tw), height: Int64(th),
                          channels: Int64(channels), dataType: floatOut ? 1 : 0,
                          timestamp: timestamp, textureId: textureId))
    }

    /// BGRA rows → packed interleaved RGB(A)/BGR(A), uint8 or float32 0..1.
    static func layout(bgra: UnsafePointer<UInt8>, rowBytes: Int, width: Int, height: Int,
                       channels: Int, bgr: Bool, float32: Bool, into dst: UnsafeMutablePointer<UInt8>) {
        let f = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: Float.self)
        var o = 0
        for y in 0..<height {
            let r = bgra + y * rowBytes
            for x in 0..<width {
                let p = r + x * 4
                let b = p[0], g = p[1], rr = p[2], a = p[3]
                let c0 = bgr ? b : rr, c2 = bgr ? rr : b
                if float32 {
                    f[o] = Float(c0) / 255; f[o + 1] = Float(g) / 255; f[o + 2] = Float(c2) / 255
                    if channels == 4 { f[o + 3] = Float(a) / 255 }
                } else {
                    dst[o] = c0; dst[o + 1] = g; dst[o + 2] = c2
                    if channels == 4 { dst[o + 3] = a }
                }
                o += channels
            }
        }
    }

    deinit { retireBorrowed(out) }
}
