package dev.shreeman.nitro_camera.outputs

import android.media.Image
import java.nio.ByteBuffer
import java.nio.ByteOrder
import nitro.nitro_camera_module.SyncedFrame

/**
 * Pairs each video frame with the depth map from the same capture
 * (vision-camera's CameraOutputSynchronizer). Both arrive on their own
 * ImageReader with the SAME sensor timestamp; whichever comes second
 * completes the pair. Each side is copied into this output's own buffers,
 * so the plain frame / depth streams never overwrite a pending pair.
 */
internal class SyncOutput(
    private val textureId: Long,
    private val isFrontFacing: Boolean,
    private val emit: (SyncedFrame) -> Unit,
) {
    private class Pixels(val buffer: ByteBuffer, val size: Int, val width: Int, val height: Int, val rowStride: Int)
    private class Depth(val buffer: ByteBuffer, val width: Int, val height: Int)

    private val pairer = TimestampPairer<Pixels, Depth>()
    private var pixelBuffer: ByteBuffer? = null
    private var depthBuffer: ByteBuffer? = null

    /** A video image, still open (FrameOutput.onSyncImage). */
    fun onImage(image: Image) {
        val plane = image.planes[0]
        val src = plane.buffer
        val n = src.remaining()
        val buf = pixelBuffer?.takeIf { it.capacity() >= n } ?: ByteBuffer.allocateDirect(n).also { pixelBuffer = it }
        buf.clear(); buf.put(src); buf.flip()
        pairer.offerFirst(image.timestamp, Pixels(buf, n, image.width, image.height, plane.rowStride))?.let(::send)
    }

    /** A converted depth map (DepthOutput.onSyncDepth). */
    fun onDepth(sensorTimestampNs: Long, metres: ByteBuffer, width: Int, height: Int) {
        val n = width * height * 4
        val buf = depthBuffer?.takeIf { it.capacity() >= n }
            ?: ByteBuffer.allocateDirect(n).order(ByteOrder.LITTLE_ENDIAN).also { depthBuffer = it }
        buf.clear(); metres.rewind(); buf.put(metres); buf.flip()
        pairer.offerSecond(sensorTimestampNs, Depth(buf, width, height))?.let(::send)
    }

    private fun send(pair: Pair<Pixels, Depth>) {
        val (px, d) = pair
        emit(
            SyncedFrame(
                px.buffer, px.size.toLong(), px.width.toLong(), px.height.toLong(), px.rowStride.toLong(),
                0L /* YUV luma, like CameraFrame */, if (isFrontFacing) 1L else 0L,
                d.buffer, (d.width * d.height * 4).toLong(), d.width.toLong(), d.height.toLong(), (d.width * 4).toLong(),
                System.currentTimeMillis(), textureId,
            ),
        )
    }
}

/**
 * Matches two streams by an exact key (the sensor timestamp): each side keeps
 * its latest unmatched item, and an arrival whose key matches the other
 * side's pending item completes the pair. A pending item older than a newer
 * arrival on the other side can never match, so it is dropped.
 * Platform-free (JVM-tested).
 */
class TimestampPairer<A : Any, B : Any> {
    private var firstKey = 0L
    private var first: A? = null
    private var secondKey = 0L
    private var second: B? = null

    @Synchronized
    fun offerFirst(key: Long, value: A): Pair<A, B>? {
        val pending = second
        if (pending != null && secondKey == key) {
            second = null
            first = null
            return value to pending
        }
        first = value
        firstKey = key
        if (pending != null && secondKey < key) second = null
        return null
    }

    @Synchronized
    fun offerSecond(key: Long, value: B): Pair<A, B>? {
        val pending = first
        if (pending != null && firstKey == key) {
            first = null
            second = null
            return pending to value
        }
        second = value
        secondKey = key
        if (pending != null && firstKey < key) first = null
        return null
    }
}
