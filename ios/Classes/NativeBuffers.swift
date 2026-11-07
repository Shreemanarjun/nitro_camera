import CoreVideo
import QuartzCore
import os

/// Pixel buffers handed to Dart as `CameraFrame.nativeBuffer` (a retained
/// `CVPixelBufferRef`), one per session at a time, released by
/// `releaseNativeBuffer`, when the session closes, or `leaseSeconds` after
/// delivery (reclaims buffers nobody released, so they never stop for good).
enum NativeBuffers {
    static let leaseSeconds: CFTimeInterval = 1
    private static var held = [Int64: (textureId: Int64, at: CFTimeInterval)]() // by handle
    private static var lock = os_unfair_lock()

    /// Whether `textureId` still holds a live lease (expired ones are reclaimed here).
    static func isHolding(_ textureId: Int64) -> Bool {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        let expired = held.filter { $0.value.textureId == textureId && now - $0.value.at > leaseSeconds }.map(\.key)
        os_unfair_lock_unlock(&lock)
        expired.forEach(release)
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return held.values.contains { $0.textureId == textureId }
    }

    static func hold(_ buffer: CVPixelBuffer, textureId: Int64) -> Int64 {
        let handle = Int64(Int(bitPattern: Unmanaged.passRetained(buffer).toOpaque()))
        os_unfair_lock_lock(&lock)
        held[handle] = (textureId, CACurrentMediaTime())
        os_unfair_lock_unlock(&lock)
        return handle
    }

    static func release(_ handle: Int64) {
        os_unfair_lock_lock(&lock)
        let known = held.removeValue(forKey: handle) != nil
        os_unfair_lock_unlock(&lock)
        guard known, let ptr = UnsafeRawPointer(bitPattern: Int(handle)) else { return }
        Unmanaged<CVPixelBuffer>.fromOpaque(ptr).release()
    }

    static func releaseAll(_ textureId: Int64) {
        os_unfair_lock_lock(&lock)
        let handles = held.filter { $0.value.textureId == textureId }.map(\.key)
        os_unfair_lock_unlock(&lock)
        handles.forEach(release)
    }
}
