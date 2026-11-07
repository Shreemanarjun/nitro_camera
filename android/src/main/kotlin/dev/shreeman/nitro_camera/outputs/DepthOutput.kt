package dev.shreeman.nitro_camera.outputs

import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.media.ImageReader
import android.os.Handler
import android.util.Log
import android.util.Size
import android.view.Surface
import nitro.nitro_camera_module.DepthFrame
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * DEPTH16 stream (cameras with the DEPTH_OUTPUT capability) converted to
 * float32 metres for [DepthFrame] — vision-camera's CameraDepthFrameOutput.
 * One reused direct buffer; frames are borrowed by the Dart listener.
 */
internal class DepthOutput(size: Size, private val textureId: Long, handler: Handler,
                           private val onFrame: (DepthFrame) -> Unit) {
    private val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.DEPTH16, 2)
    val surface: Surface get() = reader.surface
    private var out: ByteBuffer? = null

    init {
        reader.setOnImageAvailableListener({ r ->
            val image = try { r.acquireLatestImage() } catch (_: Exception) { null } ?: return@setOnImageAvailableListener
            try {
                val plane = image.planes[0]
                val w = image.width
                val h = image.height
                val src = plane.buffer.order(ByteOrder.LITTLE_ENDIAN)
                val dst = out?.takeIf { it.capacity() == w * h * 4 }
                    ?: ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.LITTLE_ENDIAN).also { out = it }
                dst.clear()
                toMetres(src, plane.rowStride, plane.pixelStride, w, h, dst)
                dst.rewind()
                onFrame(DepthFrame(dst, (w * h * 4).toLong(), w.toLong(), h.toLong(), (w * 4).toLong(),
                    System.currentTimeMillis(), textureId))
            } catch (e: Exception) {
                Log.w("NitroCamera", "depth[$textureId]: ${e.message}")
            } finally {
                image.close()
            }
        }, handler)
    }

    fun close() = reader.close()

    companion object {
        /** Depth stream size: the largest DEPTH16 size up to 640 px wide. */
        fun sizeFor(chars: CameraCharacteristics): Size? {
            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: return null
            if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT)) return null
            val sizes = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(ImageFormat.DEPTH16)?.takeIf { it.isNotEmpty() } ?: return null
            return sizes.filter { it.width <= 640 }.maxByOrNull { it.width * it.height }
                ?: sizes.minByOrNull { it.width * it.height }
        }

        /**
         * DEPTH16 → float32 metres: the low 13 bits are millimetres, the top 3
         * a confidence code where 1 means "0 % confident" (reported as 0 m,
         * like a missing sample).
         */
        fun toMetres(src: ByteBuffer, rowStride: Int, pixelStride: Int, w: Int, h: Int, dst: ByteBuffer) {
            for (y in 0 until h) {
                val row = y * rowStride
                for (x in 0 until w) {
                    val v = src.getShort(row + x * pixelStride).toInt() and 0xFFFF
                    val confidence = (v shr 13) and 0x7
                    val mm = v and 0x1FFF
                    dst.putFloat(if (confidence == 1) 0f else mm / 1000f)
                }
            }
        }
    }
}
