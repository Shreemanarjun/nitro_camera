package dev.shreeman.nitro_camera.utils

import android.hardware.HardwareBuffer
import android.media.Image
import java.util.concurrent.ConcurrentHashMap

/**
 * Camera images whose `AHardwareBuffer*` was handed to Dart
 * (CameraFrame.nativeBuffer). The image stays open — so the camera can't
 * recycle the buffer — until [release] or [LEASE_MS] after delivery; one per
 * session at a time, which a 2-image reader always tolerates. The lease
 * reclaims buffers nobody released (no listener, a filtered-out frame, a
 * forgotten release) so native buffers never stop for good.
 */
internal object NativeBuffers {
    const val LEASE_MS = 1000L

    private class Held(val textureId: Long, val image: Image, val buffer: HardwareBuffer,
                       val at: Long = android.os.SystemClock.elapsedRealtime())

    private val held = ConcurrentHashMap<Long, Held>()

    @JvmStatic private external fun nativeHandle(buffer: HardwareBuffer): Long

    /** Whether [textureId] still holds a live lease (expired ones are reclaimed here). */
    fun isHolding(textureId: Long): Boolean {
        val now = android.os.SystemClock.elapsedRealtime()
        held.filterValues { it.textureId == textureId && now - it.at > LEASE_MS }.keys.forEach(::release)
        return held.values.any { it.textureId == textureId }
    }

    /** Holds [image] and returns its buffer handle, or 0 (image not hardware-backed). */
    fun hold(textureId: Long, image: Image): Long {
        if (android.os.Build.VERSION.SDK_INT < 28) return 0
        val buffer = image.hardwareBuffer ?: return 0
        val handle = nativeHandle(buffer)
        if (handle == 0L) { buffer.close(); return 0 }
        held[handle] = Held(textureId, image, buffer)
        return handle
    }

    fun release(handle: Long) {
        held.remove(handle)?.let { it.buffer.close(); it.image.close() }
    }

    fun releaseAll(textureId: Long) {
        held.filterValues { it.textureId == textureId }.keys.forEach(::release)
    }
}
