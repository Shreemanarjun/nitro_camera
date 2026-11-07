import AVFoundation
import os

/// Public native extension point for OTHER plugins (an RTMP / WebRTC
/// publisher, a second encoder, …) — vision-camera v5's `CameraOutput`
/// counterpart.
///
/// A plugin registers a sink for the session behind a Flutter `textureId`
/// (`CameraController.textureId` on the Dart side) and receives every camera
/// video sample buffer the recorder would: portrait-upright, mirrored for the
/// front camera, in the session's pixel format, with the capture timing. Sinks
/// run synchronously on the session's frame queue — retain the buffer and hand
/// it off (e.g. to a VTCompressionSession); never block.
///
/// Sinks are keyed by textureId and dropped when that session closes. A new
/// textureId (device / format change) is a new session: register again.
public enum NitroCameraOutputs {
    public typealias Sink = (CMSampleBuffer) -> Void

    private static var sinks = [Int64: [String: Sink]]()
    private static var lock = os_unfair_lock()

    public static func add(textureId: Int64, id: String, sink: @escaping Sink) {
        os_unfair_lock_lock(&lock)
        sinks[textureId, default: [:]][id] = sink
        os_unfair_lock_unlock(&lock)
    }

    public static func remove(textureId: Int64, id: String) {
        os_unfair_lock_lock(&lock)
        sinks[textureId]?[id] = nil
        if sinks[textureId]?.isEmpty == true { sinks[textureId] = nil }
        os_unfair_lock_unlock(&lock)
    }

    static func deliver(_ sampleBuffer: CMSampleBuffer, textureId: Int64) {
        os_unfair_lock_lock(&lock)
        let targets = sinks[textureId]
        os_unfair_lock_unlock(&lock)
        targets?.values.forEach { $0(sampleBuffer) }
    }

    static func clear(textureId: Int64) {
        os_unfair_lock_lock(&lock)
        sinks[textureId] = nil
        os_unfair_lock_unlock(&lock)
    }
}
