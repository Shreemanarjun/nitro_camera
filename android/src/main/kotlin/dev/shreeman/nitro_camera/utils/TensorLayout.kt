package dev.shreeman.nitro_camera.utils

import java.nio.ByteBuffer

/** GL read-back → ML tensor layout (GpuResizer / NitraRenderer.runResizer). Platform-free (JVM-tested). */
object TensorLayout {
    /**
     * Converts [rgba] — `glReadPixels` output, rows BOTTOM-UP — into [out]
     * as top-down interleaved RGB(A) or BGR(A), uint8 or float32 (0..1,
     * [out]'s byte order).
     */
    fun fromGlRgba(rgba: ByteBuffer, width: Int, height: Int, channels: Int, bgr: Boolean, float32: Boolean, out: ByteBuffer) {
        for (y in 0 until height) {
            val src = (height - 1 - y) * width * 4
            for (x in 0 until width) {
                val p = src + x * 4
                val r = rgba.get(p).toInt() and 0xff
                val g = rgba.get(p + 1).toInt() and 0xff
                val b = rgba.get(p + 2).toInt() and 0xff
                val a = rgba.get(p + 3).toInt() and 0xff
                val c0 = if (bgr) b else r
                val c2 = if (bgr) r else b
                if (float32) {
                    out.putFloat(c0 / 255f); out.putFloat(g / 255f); out.putFloat(c2 / 255f)
                    if (channels == 4) out.putFloat(a / 255f)
                } else {
                    out.put(c0.toByte()); out.put(g.toByte()); out.put(c2.toByte())
                    if (channels == 4) out.put(a.toByte())
                }
            }
        }
    }
}
