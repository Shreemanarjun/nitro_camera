package dev.shreeman.nitro_camera.outputs

import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.media.ImageReader
import android.os.Handler
import android.util.Log
import android.view.Surface
import dev.shreeman.nitro_camera.extensions.isFrontFacing
import dev.shreeman.nitro_camera.extensions.sensorOrientationDegrees
import dev.shreeman.nitro_camera.session.ConstraintResolver
import dev.shreeman.nitro_camera.utils.NativeBuffers
import dev.shreeman.nitro_camera.utils.NitraDetectors
import nitro.nitro_camera_module.CameraFrame
import java.nio.ByteBuffer

/**
 * Owns the frame-processing YUV stream: the [ImageReader], the per-frame
 * emission into the Dart frame stream (sampling + pooled direct buffer) and
 * the native ML detector dispatch.
 *
 * vision-camera analogue: android/.../hybrids/outputs/HybridFrameOutput.kt
 * (their ImageAnalysis-based frame output; ours reads a Camera2 YUV_420_888
 * ImageReader that the session wires into the capture request on demand —
 * see CameraSession.sendPreviewRequest for the recorder mutual-exclusion).
 */
class FrameOutput(
    private val characteristics: CameraCharacteristics,
    private val textureId: Long,
    requestedWidth: Int,
    requestedHeight: Int,
) {
    /** Resolved YUV stream size (must be advertised — see [ConstraintResolver]). */
    val size = ConstraintResolver.resolveFrameReaderSize(
        characteristics, requestedWidth, requestedHeight)

    private val reader = ImageReader.newInstance(
        size.width, size.height, ImageFormat.YUV_420_888, 2)

    /** The YUV stream surface the session wires into the capture session. */
    val surface: Surface get() = reader.surface

    // @Volatile: set from the Dart/nitro thread (setFrameFormat/setSamplingRate),
    // read on the camera thread (emitFrame / state read-back).
    // The Android pipeline is hard-wired to YUV_420_888 (the ImageReader above),
    // so 0 (yuv420) is the only value ever delivered on frames; keeping this at
    // anything else would make ResolvedConfig/session state contradict every
    // CameraFrame header.
    @Volatile var pixelFormat: Long = 0
    @Volatile var samplingRate: Long = 1
    /** Attach the image's AHardwareBuffer to frames (setNativeBuffers). */
    @Volatile var nativeBuffers = false

    /** Delivery callback into the shared frame flow (set by NitroCameraImpl via the session). */
    var onFrame: ((CameraFrame) -> Unit)? = null

    private var frameCounter: Long = 0
    // Diagnostics counter for the rate-limited frameReader log (camera thread only).
    private var frameImgCount: Long = 0
    private var directBuffer: ByteBuffer? = null

    /**
     * Installs the image-available listener on [handler] (the camera thread).
     * The image is ALWAYS acquired and closed to free the buffer pool, even if
     * processing is currently disabled. [NitraDetectors] copies what it needs
     * SYNCHRONOUSLY (the image is closed right after the call) and runs the ML
     * model async with drop-while-busy throttling.
     */
    fun installListener(
        handler: Handler,
        isClosed: () -> Boolean,
        frameProcessingEnabled: () -> Boolean,
        nativeDetector: () -> String,
        onDetection: (String) -> Unit,
    ) {
        reader.setOnImageAvailableListener({ r ->
            if (isClosed()) return@setOnImageAvailableListener

            // ALWAYS acquire and close the image to free the buffer pool,
            // even if processing is currently disabled.
            val image = try { r.acquireLatestImage() } catch (_: Exception) { null }
                ?: return@setOnImageAvailableListener

            frameImgCount++
            if (frameImgCount % 120 == 1L) {
                Log.d("NitroCamera", "frameReader[$textureId]: img#$frameImgCount " +
                    "enabled=${frameProcessingEnabled()} det='${nativeDetector()}' sampling=$samplingRate")
            }

            var handle = 0L
            try {
                val det = nativeDetector()
                if (det.isNotEmpty()) {
                    NitraDetectors.process(image, characteristics, textureId, det, onDetection)
                }
                if (frameProcessingEnabled()) {
                    if (nativeBuffers && !NativeBuffers.isHolding(textureId)) {
                        handle = NativeBuffers.hold(textureId, image)
                    }
                    if (!emitFrame(image, handle) && handle != 0L) {
                        NativeBuffers.release(handle) // not delivered: give it back
                        handle = 0L
                    }
                }
            } finally {
                if (handle == 0L) image.close() // a held image closes on release
            }
        }, handler)
    }

    /** Returns whether the frame was delivered. */
    private fun emitFrame(image: android.media.Image, nativeBuffer: Long): Boolean {
        val cb = onFrame ?: return false
        try {
            frameCounter++
            if (frameCounter % samplingRate != 0L) return false
            val plane = image.planes[0]
            val src = plane.buffer
            val size = src.remaining().toLong()
            var buffer = directBuffer
            if (buffer == null || buffer.capacity() < src.remaining()) {
                buffer = ByteBuffer.allocateDirect(src.remaining()); directBuffer = buffer
            }
            buffer!!.clear(); buffer.put(src); buffer.flip()
            val orientation = characteristics.sensorOrientationDegrees(0)
            val rotation = when (orientation) {
                90 -> 90
                270 -> 270
                180 -> 180
                else -> 0
            }
            // The frame reader delivers YUV_420_888; plane[0] is the luma plane,
            // whose row stride (`rowStride`) may exceed width due to alignment.
            val isFront = characteristics.isFrontFacing

            cb(CameraFrame(buffer, size, image.width.toLong(), image.height.toLong(),
                System.currentTimeMillis(), rotation.toLong(), textureId,
                plane.rowStride.toLong(), 0L /* YUV luma */, if (isFront) 1L else 0L, nativeBuffer))
            return true
        } catch (_: Exception) {
            return false
        }
    }

    /** Releases held buffers, then closes the underlying ImageReader. */
    fun close() {
        NativeBuffers.releaseAll(textureId)
        reader.close()
    }
}
