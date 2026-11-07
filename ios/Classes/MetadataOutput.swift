import AVFoundation

/// AVCaptureMetadataOutput detectors — vision-camera's object output:
/// "hardwareFace" (faces) and "hardwareCode" (barcodes), detected by the
/// camera pipeline with no frame copies. Emits the same `detection` JSON as
/// the frame detectors; bounds are normalised (`width`/`height` = 1) in the
/// sensor's landscape space (`rotation` = 90 → turn clockwise to upright).
final class MetadataOutput: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let output = AVCaptureMetadataOutput()
    let detector: String
    private let queue = DispatchQueue(label: "dev.shreeman.nitro_camera.metadata")
    private let mirrored: Bool
    private var lastEmit: CFTimeInterval = 0
    private var lastEmpty: CFTimeInterval = 0
    var onJson: ((String) -> Void)?

    static let codeTypes: [AVMetadataObject.ObjectType] = [
        .qr, .ean13, .ean8, .upce, .code128, .code39, .code93, .pdf417, .aztec,
        .dataMatrix, .itf14, .interleaved2of5,
    ]

    init(detector: String, mirrored: Bool) {
        self.detector = detector
        self.mirrored = mirrored
        super.init()
        output.setMetadataObjectsDelegate(self, queue: queue)
    }

    /// Call after the output joined the session (types depend on it).
    /// Returns false when the session offers none of the wanted types.
    func activate() -> Bool {
        let wanted = detector == "hardwareFace" ? [.face] : Self.codeTypes
        let types = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
        output.metadataObjectTypes = types
        return !types.isEmpty
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        if now - lastEmit < 0.1 { return }
        if objects.isEmpty { if now - lastEmpty < 0.5 { return }; lastEmpty = now }
        lastEmit = now
        let results: [[String: Any]] = objects.map { obj in
            let b = obj.bounds
            var item: [String: Any] = ["bounds": [b.minX, b.minY, b.maxX, b.maxY]]
            if let face = obj as? AVMetadataFaceObject {
                if face.hasRollAngle { item["headEulerAngleZ"] = Double(face.rollAngle) }
                if face.hasYawAngle { item["headEulerAngleY"] = Double(face.yawAngle) }
                item["trackingId"] = face.faceID
            } else if let code = obj as? AVMetadataMachineReadableCodeObject {
                item["text"] = code.stringValue ?? ""
                item["format"] = code.type.rawValue
            }
            return item
        }
        let json: [String: Any] = ["detector": detector, "width": 1, "height": 1, "rotation": 90,
                                   "mirrored": mirrored, "results": results]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let s = String(data: data, encoding: .utf8) { onJson?(s) }
    }

    func teardown() {
        output.setMetadataObjectsDelegate(nil, queue: nil)
        queue.sync {}
        onJson = nil
    }
}
