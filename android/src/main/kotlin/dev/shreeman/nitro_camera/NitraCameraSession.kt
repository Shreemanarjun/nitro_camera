package dev.shreeman.nitro_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.hardware.camera2.params.MeteringRectangle
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import nitro.nitro_camera_module.*
import java.nio.ByteBuffer

import android.hardware.camera2.CameraDevice as AndroidCameraDevice

/**
 * Manages one Camera2 session per open camera.
 */
@SuppressLint("MissingPermission")
class NitraCameraSession(
    private val context: Context,
    val textureId: Long,
    private val surfaceEntry: TextureRegistry.SurfaceTextureEntry?,
    private val surfaceProducer: Any?, // TextureRegistry.SurfaceProducer
    private val cameraDevice: AndroidCameraDevice,
    private val characteristics: CameraCharacteristics,
    private val width: Int,
    private val height: Int,
    private val requestedFps: Int,
    private val enableAudio: Boolean,
) {
    private val cameraThread = HandlerThread("NitraSession-$textureId").also { it.start() }
    val cameraHandler = Handler(cameraThread.looper)

    private val glThread = HandlerThread("NitraGLThread").apply { start() }
    private val glHandler = Handler(glThread.looper)

    private val renderer = NitraRenderer(width, height)

    private var previewSurface: Surface? = null

    // --- Persistent Camera State ---
    private var zoomValue: Double = 1.0
    private var flashMode: Long = 0L
    private var exposureValue: Double = 0.0
    private var afMode: Long = 1L
    private var torchEnabled: Boolean = false

    init {
        val latch = java.util.concurrent.CountDownLatch(1)
        glHandler.post {
            try {
                // Determine source surface from modern producer or legacy entry
                val inputSurface: Surface = when {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && surfaceProducer != null -> {
                        val producer = surfaceProducer as io.flutter.view.TextureRegistry.SurfaceProducer
                        producer.setSize(width, height)
                        producer.getSurface()
                    }
                    else -> {
                        val st = surfaceEntry?.surfaceTexture() ?: throw IllegalStateException("No surface source")
                        st.setDefaultBufferSize(width, height)
                        Surface(st)
                    }
                }
                renderer.setup(inputSurface)
            } catch (e: Exception) {
                Log.e("NitroCamera", "GL Setup Error: ${e.message}")
            } finally {
                latch.countDown()
            }
        }
        try { latch.await(1000, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: Exception) {}

        // Listen to SurfaceProducer lifecycle if available
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && surfaceProducer != null) {
            val producer = surfaceProducer as io.flutter.view.TextureRegistry.SurfaceProducer
            producer.setCallback(object : io.flutter.view.TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                   glHandler.post { startPreview() }
                }

                override fun onSurfaceCleanup() {
                    cameraHandler.post { stopPreview() }
                }
            })
        }
    }

    @Volatile private var isClosed = false
    @Volatile private var captureSession: CameraCaptureSession? = null

    var frameProcessingEnabled = false
        set(value) {
            if (field != value) {
                field = value
                captureSession?.let { sendPreviewRequest(it) }
            }
        }
    var onFrame: ((CameraFrame) -> Unit)? = null
    private var pixelFormat: Long = 1
    private var samplingRate: Long = 1
    private var frameCounter: Long = 0
    private val frameReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2)
    private var directBuffer: ByteBuffer? = null

    val mediaManager = NitraMediaManager(
        context, cameraDevice, characteristics, cameraHandler, width, height, enableAudio
    )

    private fun bestFpsRange(): android.util.Range<Int>? {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?: return null
        return if (requestedFps <= 0) {
            ranges.maxByOrNull { it.upper }
        } else {
            ranges.filter { it.upper >= requestedFps }
                .minByOrNull { it.upper - requestedFps + if (it.lower == it.upper) 0 else 1 }
                ?: ranges.maxByOrNull { it.upper }
        }
    }

    fun startPreview() {
        if (isClosed) return

        // Ensure renderer surface is ready
        val pSurface = renderer.inputSurface ?: return
        previewSurface = pSurface

        val surfaces = mutableListOf(pSurface, mediaManager.photoReader.surface, frameReader.surface)

        try {
            cameraDevice.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (isClosed) { session.close(); return }
                        captureSession = session
                        sendPreviewRequest(session)
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e("NitroCamera", "Preview session config failed")
                    }
                },
                cameraHandler,
            )
        } catch (e: Exception) {
            Log.e("NitroCamera", "createCaptureSession failed: ${e.message}")
        }

        frameReader.setOnImageAvailableListener({ reader ->
            if (isClosed || !frameProcessingEnabled) return@setOnImageAvailableListener
            val image = try { reader.acquireLatestImage() } catch (_: Exception) { null }
                ?: return@setOnImageAvailableListener
            try { emitFrame(image) } finally { image.close() }
        }, cameraHandler)
    }

    private fun sendPreviewRequest(session: CameraCaptureSession) {
        if (isClosed) return
        val inputST = renderer.inputSurfaceTexture ?: return
        inputST.setOnFrameAvailableListener(null)
        inputST.setOnFrameAvailableListener({
            glHandler.post {
                if (!isClosed) {
                    try { renderer.drawFrame() } catch (e: Exception) { Log.e("NitroCamera", "Render error: ${e.message}") }
                }
            }
        }, glHandler)

        try {
            val builder = cameraDevice.createCaptureRequest(android.hardware.camera2.CameraDevice.TEMPLATE_PREVIEW)
            val pSurface = previewSurface ?: return
            builder.addTarget(pSurface)
            if (frameProcessingEnabled) {
                builder.addTarget(frameReader.surface)
            }
            applySessionSettings(builder)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "setRepeatingRequest failed: ${e.message}")
        }
    }

    fun stopPreview() {
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
    }

    private fun applySessionSettings(builder: CaptureRequest.Builder) {
        val af = when (afMode) {
            0L   -> CaptureRequest.CONTROL_AF_MODE_OFF
            2L   -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            else -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
        }
        builder.set(CaptureRequest.CONTROL_AF_MODE, af)

        val availableAeModes = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES) ?: intArrayOf()
        var ae = CaptureRequest.CONTROL_AE_MODE_ON

        when (flashMode) {
            1L -> if (availableAeModes.contains(CaptureRequest.CONTROL_AE_MODE_ON_ALWAYS_FLASH)) {
                ae = CaptureRequest.CONTROL_AE_MODE_ON_ALWAYS_FLASH
            }
            2L -> if (availableAeModes.contains(CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH)) {
                ae = CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH
            }
        }
        builder.set(CaptureRequest.CONTROL_AE_MODE, ae)

        if (torchEnabled) {
            builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
        } else if (flashMode == 1L) {
            builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_SINGLE)
        } else {
            builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
        }

        val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        if (rect != null) {
            val maxZ = (characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
            val clamped = zoomValue.coerceIn(1.0, maxZ).toFloat()
            val cx = rect.width() / 2; val cy = rect.height() / 2
            val dx = (rect.width() / (2 * clamped)).toInt()
            val dy = (rect.height() / (2 * clamped)).toInt()
            builder.set(CaptureRequest.SCALER_CROP_REGION, Rect(cx - dx, cy - dy, cx + dx, cy + dy))
        }

        val range = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        if (range != null) {
            val step = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toDouble() ?: 1.0
            val ev = if (step == 0.0) 0 else (exposureValue / step).toInt().coerceIn(range.lower, range.upper)
            builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, ev)
        }

        bestFpsRange()?.let { builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
    }

    suspend fun close() {
        if (isClosed) return
        isClosed = true
        kotlinx.coroutines.delay(100)
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null
        try { cameraDevice.close() } catch (_: Exception) {}
        try { renderer.inputSurfaceTexture?.release() } catch (_: Exception) {}
        try { frameReader.close() } catch (_: Exception) {}
        mediaManager.release()

        val releaseLatch = java.util.concurrent.CountDownLatch(1)
        if (glHandler.looper.thread.isAlive) {
            glHandler.postAtFrontOfQueue {
                try { renderer.release() } finally {
                    glThread.quitSafely()
                    releaseLatch.countDown()
                }
            }
            try { releaseLatch.await(1000, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: Exception) {}
        } else {
            releaseLatch.countDown()
        }

        withContext(Dispatchers.Main) {
            surfaceEntry?.release()
            (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)?.release()
        }
        cameraThread.quitSafely()
    }

    fun setZoom(zoom: Double) { zoomValue = zoom; triggerUpdate() }
    fun setFlash(mode: Long) { flashMode = mode; triggerUpdate() }
    fun setTorch(enabled: Boolean) { torchEnabled = enabled; triggerUpdate() }
    fun setExposure(value: Double) { exposureValue = value; triggerUpdate() }
    fun setAutoFocus(mode: Long) { afMode = mode; triggerUpdate() }

    private fun triggerUpdate() {
        if (isClosed) return
        cameraHandler.post {
            val session = captureSession ?: return@post
            if (isClosed) return@post
            try {
                val template = if (mediaManager.isRecording)
                    AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW
                val builder = cameraDevice.createCaptureRequest(template)
                val pSurface = previewSurface ?: return@post
                builder.addTarget(pSurface)
                applySessionSettings(builder)
                session.setRepeatingRequest(builder.build(), null, cameraHandler)
            } catch (e: Exception) { Log.w("NitroCamera", "Update failed: ${e.message}") }
        }
    }

    fun setFocusPoint(x: Double, y: Double) {
        if (isClosed) return
        val session = captureSession ?: return
        cameraHandler.post {
            if (isClosed) return@post
            try {
                val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return@post
                val orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

                // 1. Correct mirroring for Front Camera
                val isFront = characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
                var finalX = if (isFront) 1.0 - x else x
                var finalY = y

                // 2. Map coordinates relative to sensor orientation
                when (orientation) {
                    90 -> { val tmp = finalX; finalX = finalY; finalY = 1.0 - tmp }
                    270 -> { val tmp = finalX; finalX = 1.0 - finalY; finalY = tmp }
                    180 -> { finalX = 1.0 - finalX; finalY = 1.0 - finalY }
                }

                val pSurface = previewSurface ?: return@post
                if (!pSurface.isValid) return@post

                val fx = (finalX * rect.width()).toInt().coerceIn(100, rect.width() - 100)
                val fy = (finalY * rect.height()).toInt().coerceIn(100, rect.height() - 100)

                val metering = MeteringRectangle(Rect(fx - 100, fy - 100, fx + 100, fy + 100), 1000)

                val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_PREVIEW)

                builder.addTarget(pSurface)
                applySessionSettings(builder)
                builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(metering))
                builder.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(metering))
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
                session.capture(builder.build(), null, cameraHandler)
            } catch (e: Exception) { Log.w("NitroCamera", "setFocusPoint: ${e.message}") }
        }
    }

    fun setWhiteBalance(temperature: Long) { /* Implementation stub */ }
    fun setHdr(enabled: Boolean) { /* Implementation stub */ }

    fun setFrameFormat(format: Long)     { pixelFormat = format }
    fun setSamplingRate(rate: Long)     { samplingRate = rate }
    fun setFilterShader(source: String) { renderer.updateShader(source) }

    suspend fun takePhoto(): PhotoResult {
        val session = captureSession ?: throw Exception("No active session")
        val builder = cameraDevice.createCaptureRequest(android.hardware.camera2.CameraDevice.TEMPLATE_STILL_CAPTURE)
        builder.addTarget(mediaManager.photoReader.surface)

        applySessionSettings(builder)

        // JPEG orientation
        val orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        builder.set(CaptureRequest.JPEG_ORIENTATION, orientation)

        return mediaManager.takePhotoWithRequest(session, builder.build()) {
            // Resume repeating request after capture completes
            cameraHandler.post { triggerUpdate() }
        }
    }

    fun startVideoRecording(outputPath: String) {
        if (isClosed) return
        cameraHandler.post {
            if (isClosed) return@post
            try {
                val recSurface = mediaManager.prepareVideoRecorder(outputPath)
                val pSurface = previewSurface ?: return@post
                val surfaces = mutableListOf(pSurface, recSurface, mediaManager.photoReader.surface)
                cameraDevice.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (isClosed) { session.close(); return }
                        captureSession = session
                        try {
                            val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_RECORD)
                            builder.addTarget(pSurface)
                            builder.addTarget(recSurface)
                            applySessionSettings(builder)
                            session.setRepeatingRequest(builder.build(), null, cameraHandler)
                            mediaManager.startVideoRecorder()
                        } catch (e: Exception) { Log.e("NitroCamera", "Record request failed: ${e.message}") }
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        mediaManager.stopVideoRecording()
                    }
                }, cameraHandler)
            } catch (e: Exception) { Log.e("NitroCamera", "startVideoRecording: ${e.message}") }
        }
    }

    fun stopVideoRecording(): RecordingResult {
        try { captureSession?.stopRepeating() } catch (e: Exception) { }
        try { captureSession?.close() } catch (e: Exception) { }
        captureSession = null
        val result = mediaManager.stopVideoRecording()
        if (!isClosed) cameraHandler.postDelayed({ if (!isClosed) startPreview() }, 150)
        return result
    }

    fun pauseVideoRecording()  { mediaManager.pauseVideoRecording() }
    fun resumeVideoRecording() { mediaManager.resumeVideoRecording() }
    fun cancelVideoRecording() { mediaManager.stopVideoRecording(); startPreview() }

    private fun emitFrame(image: android.media.Image) {
        val cb = onFrame ?: return
        try {
            frameCounter++
            if (frameCounter % samplingRate != 0L) return
            val plane = image.planes[0]
            val src = plane.buffer
            val size = src.remaining().toLong()
            var buffer = directBuffer
            if (buffer == null || buffer.capacity() < src.remaining()) {
                buffer = ByteBuffer.allocateDirect(src.remaining()); directBuffer = buffer
            }
            buffer!!.clear(); buffer.put(src); buffer.flip()
            val orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val rotation = when (orientation) {
                90 -> 90
                270 -> 270
                180 -> 180
                else -> 0
            }

            cb(CameraFrame(buffer, size, image.width.toLong(), image.height.toLong(),
                System.currentTimeMillis(), rotation.toLong(), textureId))
        } catch (_: Exception) { }
    }
}
