package dev.shreeman.nitro_camera

import android.view.Surface
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Public native extension point for OTHER plugins (an RTMP / WebRTC publisher,
 * a second encoder, …) — vision-camera v5's `CameraOutput` counterpart.
 *
 * A plugin hands in a [Surface] it consumes (e.g. a MediaCodec input surface or
 * its own SurfaceTexture) for the session behind a Flutter `textureId`
 * (`CameraController.textureId` on the Dart side). Every camera frame is then
 * drawn into it by the session's GL renderer: upright, cover-cropped to the
 * surface's aspect, un-mirrored unless [mirror] is set, with the sensor
 * timestamp as the EGL presentation time. The camera's stream configuration is
 * untouched, so attaching never reopens the device; a session on the direct
 * (no-GL) preview switches to the GL renderer first.
 *
 * Outputs are keyed by textureId and survive the session being created after
 * [add]. A new textureId (device / format change) is a new session: register
 * again. Call [remove] BEFORE releasing the surface.
 */
object NitroCameraOutputs {
    class Output(val surface: Surface, val mirror: Boolean)

    private val outputs = ConcurrentHashMap<Long, CopyOnWriteArrayList<Output>>()
    private val listeners = ConcurrentHashMap<Long, () -> Unit>()

    @JvmStatic
    @JvmOverloads
    fun add(textureId: Long, surface: Surface, mirror: Boolean = false) {
        val list = outputs.getOrPut(textureId) { CopyOnWriteArrayList() }
        list.removeAll { it.surface == surface }
        list.add(Output(surface, mirror))
        listeners[textureId]?.invoke()
    }

    @JvmStatic
    fun remove(textureId: Long, surface: Surface) {
        val list = outputs[textureId] ?: return
        if (list.removeAll { it.surface == surface }) listeners[textureId]?.invoke()
        if (list.isEmpty()) outputs.remove(textureId, list)
    }

    internal fun outputsFor(textureId: Long): List<Output> = outputs[textureId] ?: emptyList()

    internal fun listen(textureId: Long, onChange: (() -> Unit)?) {
        if (onChange == null) listeners.remove(textureId) else listeners[textureId] = onChange
    }

    /** Session closed for good: its id is never reused. */
    internal fun clear(textureId: Long) {
        listeners.remove(textureId)
        outputs.remove(textureId)
    }
}
