import CoreImage
import UIKit

/// A decoded `CameraOverlay` command (Dart `CameraOverlay.encode`).
/// Coordinates are normalised to the upright frame (0..1, top-left origin);
/// sizes are fractions of the frame's shorter side.
enum OverlayCommand: Equatable {
    case rect(argb: UInt32, l: Float, t: Float, r: Float, b: Float, stroke: Float)
    case circle(argb: UInt32, x: Float, y: Float, radius: Float, stroke: Float)
    case line(argb: UInt32, x1: Float, y1: Float, x2: Float, y2: Float, stroke: Float)
    case text(argb: UInt32, x: Float, y: Float, size: Float, text: String)

    /// Parses the wire form. A malformed buffer yields what was read before the fault.
    static func parse(_ data: Data) -> [OverlayCommand] {
        var r = Reader(bytes: [UInt8](data))
        guard r.u8() == 1, let count = r.u32() else { return [] }
        var out: [OverlayCommand] = []
        for _ in 0..<min(Int(count), 4096) {
            guard let op = r.u8(), let argb = r.u32() else { break }
            switch op {
            case 0:
                guard let l = r.f32(), let t = r.f32(), let rr = r.f32(), let b = r.f32(), let s = r.f32() else { return out }
                out.append(.rect(argb: argb, l: l, t: t, r: rr, b: b, stroke: s))
            case 1:
                guard let x = r.f32(), let y = r.f32(), let rad = r.f32(), let s = r.f32() else { return out }
                out.append(.circle(argb: argb, x: x, y: y, radius: rad, stroke: s))
            case 2:
                guard let x1 = r.f32(), let y1 = r.f32(), let x2 = r.f32(), let y2 = r.f32(), let s = r.f32() else { return out }
                out.append(.line(argb: argb, x1: x1, y1: y1, x2: x2, y2: y2, stroke: s))
            case 3:
                guard let x = r.f32(), let y = r.f32(), let size = r.f32(), let n = r.u32(),
                      let bytes = r.bytes(Int(n)) else { return out }
                out.append(.text(argb: argb, x: x, y: y, size: size, text: String(decoding: bytes, as: UTF8.self)))
            default:
                return out // unknown op: stop rather than misread the rest
            }
        }
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }
        mutating func u8() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }
        mutating func u32() -> UInt32? {
            guard i + 4 <= bytes.count else { return nil }
            defer { i += 4 }
            return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, i + n <= bytes.count else { return nil }
            defer { i += n }
            return Array(bytes[i..<(i + n)])
        }
    }
}

/// Rasterises overlay commands once per change and composites them over
/// camera frames on the GPU (Core Image on Metal), so the preview texture and
/// the recorder both get the drawings — the Skia-frame-processor analogue.
final class OverlayRenderer {
    private let context: CIContext
    private var commands: [OverlayCommand] = []
    private var cached: CIImage?
    private var cachedSize: CGSize = .zero
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private let lock = NSLock()

    init(context: CIContext) { self.context = context }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !commands.isEmpty
    }

    func update(_ data: Data) {
        let parsed = OverlayCommand.parse(data)
        lock.lock()
        commands = parsed
        cached = nil
        lock.unlock()
    }

    /// [src] with the overlay drawn over it, in a pooled BGRA buffer; nil when
    /// there is no overlay or compositing fails (callers then use [src]).
    func composite(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let size = CGSize(width: w, height: h)
        lock.lock()
        let cmds = commands
        var overlay = cached
        if overlay == nil || cachedSize != size, !cmds.isEmpty {
            overlay = Self.rasterise(cmds, size: size)
            cached = overlay
            cachedSize = size
        }
        lock.unlock()
        guard !cmds.isEmpty, let ov = overlay else { return nil }

        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool = pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let dst = out else { return nil }
        let composed = ov.composited(over: CIImage(cvPixelBuffer: src))
        let dest = CIRenderDestination(pixelBuffer: dst)
        do {
            try context.startTask(toRender: composed, from: composed.extent, to: dest, at: .zero).waitUntilCompleted()
        } catch {
            return nil
        }
        CVBufferPropagateAttachments(src, dst)
        return dst
    }

    /// Draws the commands into a transparent image of [size] (top-left origin).
    static func rasterise(_ commands: [OverlayCommand], size: CGSize) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let unit = min(size.width, size.height)
        func color(_ argb: UInt32) -> UIColor {
            UIColor(red: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255,
                    blue: CGFloat(argb & 0xff) / 255, alpha: CGFloat((argb >> 24) & 0xff) / 255)
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            for c in commands {
                switch c {
                case let .rect(argb, l, t, r, b, stroke):
                    let rect = CGRect(x: CGFloat(l) * size.width, y: CGFloat(t) * size.height,
                                      width: CGFloat(r - l) * size.width, height: CGFloat(b - t) * size.height)
                    if stroke > 0 {
                        cg.setStrokeColor(color(argb).cgColor); cg.setLineWidth(CGFloat(stroke) * unit); cg.stroke(rect)
                    } else {
                        cg.setFillColor(color(argb).cgColor); cg.fill(rect)
                    }
                case let .circle(argb, x, y, radius, stroke):
                    let r = CGFloat(radius) * unit
                    let rect = CGRect(x: CGFloat(x) * size.width - r, y: CGFloat(y) * size.height - r, width: 2 * r, height: 2 * r)
                    if stroke > 0 {
                        cg.setStrokeColor(color(argb).cgColor); cg.setLineWidth(CGFloat(stroke) * unit); cg.strokeEllipse(in: rect)
                    } else {
                        cg.setFillColor(color(argb).cgColor); cg.fillEllipse(in: rect)
                    }
                case let .line(argb, x1, y1, x2, y2, stroke):
                    cg.setStrokeColor(color(argb).cgColor)
                    cg.setLineWidth(max(CGFloat(stroke), 0.001) * unit)
                    cg.move(to: CGPoint(x: CGFloat(x1) * size.width, y: CGFloat(y1) * size.height))
                    cg.addLine(to: CGPoint(x: CGFloat(x2) * size.width, y: CGFloat(y2) * size.height))
                    cg.strokePath()
                case let .text(argb, x, y, sizeFrac, text):
                    let font = UIFont.systemFont(ofSize: CGFloat(sizeFrac) * unit, weight: .semibold)
                    (text as NSString).draw(at: CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height),
                                            withAttributes: [.font: font, .foregroundColor: color(argb)])
                }
            }
        }
        guard let cg = image.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}
