import Foundation
import AVFoundation
import Vision

/// Native ML detector runner (barcode / face) via the built-in Vision framework.
///
/// iOS analogue of Android's `NitraDetectors` (which probes for optional ML Kit
/// artifacts at runtime). Vision ships with the OS, so there is no dependency
/// probe here: a detector name is either known ("barcode" / "face") or rejected
/// with a single error payload, after which the detector stays disabled for
/// that texture until `stop()`.
///
/// Concurrency model (mirrors the Android runner): `process` is called on the
/// camera frame queue with the LIVE pixel buffer of the current frame. The
/// buffer is retained for the duration of exactly one Vision request —
/// drop-while-busy guarantees a single in-flight buffer per texture — and the
/// request itself runs on a dedicated background queue with a ~100 ms minimum
/// interval. Empty result sets are still emitted (so UIs can clear stale
/// highlights) but rate-limited to one per 500 ms. Results that complete after
/// `stop()` / a detector swap are suppressed.
enum NitraDetectors {

    /// Minimum interval between detection dispatches per texture (~10 Hz).
    private static let minDetectIntervalMs: Double = 100
    /// Minimum interval between EMPTY result emissions per texture.
    private static let emptyEmitIntervalMs: Double = 500

    private static var states = [Int64: DetectorState]()
    private static let statesLock = NSLock()
    /// Serial queue — at most one Vision request runs at a time.
    private static let detectQueue = DispatchQueue(
        label: "dev.shreeman.nitro_camera.detectors", qos: .userInitiated)

    /// Runs `detector` on `pixelBuffer` (throttled, drop-while-busy). The
    /// result JSON is delivered via `onResult`, possibly from another thread:
    ///
    ///     {"detector":"barcode","width":W,"height":H,"rotation":0,
    ///      "results":[{"text":...,"format":...,"bounds":[l,t,r,b]}]}
    ///     {"detector":"face","width":W,"height":H,"rotation":0,
    ///      "results":[{"bounds":[l,t,r,b]}]}
    ///
    /// `rotation` is always 0 on iOS: buffers are delivered upright (the
    /// session sets `connection.videoOrientation = .portrait`), matching the
    /// `sensorOrientation: 0` the device enumeration reports. `bounds` are
    /// PIXEL coordinates with a TOP-LEFT origin — the same convention as
    /// Android's ML Kit bounding boxes.
    static func process(
        pixelBuffer: CVPixelBuffer,
        textureId: Int64,
        detector: String,
        onResult: @escaping (String) -> Void
    ) {
        let state = obtainState(textureId: textureId, detector: detector)
        if state.disabled { return }

        guard detector == "barcode" || detector == "face" else {
            // Report once per activation, then stay silent until stop().
            state.disabled = true
            onResult(errorJson(
                detector: detector,
                message: "Unknown detector '\(detector)' — supported detectors: barcode, face"))
            return
        }

        // Drop-while-busy + minimum interval between detections.
        let now = ProcessInfo.processInfo.systemUptime * 1000
        guard state.tryBeginDetection(now: now, minIntervalMs: minDetectIntervalMs) else { return }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        detectQueue.async {
            defer { state.endDetection() }
            // Vision failure → silent drop (mirrors Android's onDone(null, 0)).
            guard let results = runVision(
                detector: detector, pixelBuffer: pixelBuffer, width: width, height: height)
            else { return }

            // Suppress results that complete after stop() / a detector swap.
            guard isCurrent(state, for: textureId) else { return }

            if results.isEmpty {
                let emitNow = ProcessInfo.processInfo.systemUptime * 1000
                guard state.shouldEmitEmpty(now: emitNow, minIntervalMs: emptyEmitIntervalMs) else { return }
            }

            let payload: [String: Any] = [
                "detector": detector,
                "width":    width,
                "height":   height,
                "rotation": 0,
                "results":  results,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            onResult(json)
        }
    }

    /// Releases any detector state held for `textureId`.
    static func stop(textureId: Int64) {
        statesLock.lock()
        defer { statesLock.unlock() }
        states[textureId] = nil
    }

    // MARK: - Vision

    /// Performs one synchronous Vision request (on `detectQueue`) and maps the
    /// observations into Android-compatible result dictionaries. Returns nil
    /// on Vision failure.
    private static func runVision(
        detector: String,
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> [[String: Any]]? {
        let request: VNImageBasedRequest = (detector == "barcode")
            ? VNDetectBarcodesRequest()
            : VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let w = Double(width)
        let h = Double(height)
        if detector == "barcode" {
            let observations = (request.results as? [VNBarcodeObservation]) ?? []
            return observations.map { obs in
                [
                    "text":   obs.payloadStringValue ?? "",
                    "format": obs.symbology.rawValue,
                    "bounds": pixelBounds(obs.boundingBox, w: w, h: h),
                ]
            }
        } else {
            let observations = (request.results as? [VNFaceObservation]) ?? []
            return observations.map { obs in
                ["bounds": pixelBounds(obs.boundingBox, w: w, h: h)]
            }
        }
    }

    /// Vision returns NORMALIZED rects with a BOTTOM-LEFT origin; convert to
    /// PIXEL coordinates with a TOP-LEFT origin as `[left, top, right, bottom]`
    /// (y_topleft = 1 - y - height, then scale by the buffer dimensions).
    private static func pixelBounds(_ rect: CGRect, w: Double, h: Double) -> [Int] {
        let left   = Double(rect.origin.x) * w
        let top    = (1.0 - Double(rect.origin.y) - Double(rect.height)) * h
        let right  = (Double(rect.origin.x) + Double(rect.width)) * w
        let bottom = top + Double(rect.height) * h
        return [Int(left.rounded()), Int(top.rounded()), Int(right.rounded()), Int(bottom.rounded())]
    }

    // MARK: - State management

    /// Returns the state for `textureId`, recycling it if the detector changed.
    private static func obtainState(textureId: Int64, detector: String) -> DetectorState {
        statesLock.lock()
        defer { statesLock.unlock() }
        if let existing = states[textureId], existing.detector == detector {
            return existing
        }
        let fresh = DetectorState(detector: detector)
        states[textureId] = fresh
        return fresh
    }

    private static func isCurrent(_ state: DetectorState, for textureId: Int64) -> Bool {
        statesLock.lock()
        defer { statesLock.unlock() }
        return states[textureId] === state
    }

    private static func errorJson(detector: String, message: String) -> String {
        let payload: [String: Any] = ["detector": detector, "error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"detector\":\"\(detector)\",\"error\":\"detector error\"}"
        }
        return json
    }
}

/// Mutable per-texture detector state. The throttle fields are shared between
/// the camera frame queue and `detectQueue`, so they are guarded by a lock;
/// `disabled` is only touched on the camera frame queue.
private final class DetectorState {
    let detector: String
    var disabled = false

    private let lock = NSLock()
    private var inFlight = false
    private var lastRunMs: Double = 0
    private var lastEmptyEmitMs: Double = 0

    init(detector: String) { self.detector = detector }

    /// Atomically claims the in-flight slot when idle and past the throttle.
    func tryBeginDetection(now: Double, minIntervalMs: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight, now - lastRunMs >= minIntervalMs else { return false }
        inFlight = true
        lastRunMs = now
        return true
    }

    func endDetection() {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
    }

    /// Rate-limits EMPTY result emissions (one per `minIntervalMs`).
    func shouldEmitEmpty(now: Double, minIntervalMs: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastEmptyEmitMs >= minIntervalMs else { return false }
        lastEmptyEmitMs = now
        return true
    }
}
