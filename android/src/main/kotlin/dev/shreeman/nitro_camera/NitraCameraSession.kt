package dev.shreeman.nitro_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.hardware.camera2.params.MeteringRectangle
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import nitro.nitro_camera_module.*
import java.nio.ByteBuffer

import android.hardware.camera2.CameraDevice as AndroidCameraDevice

/**
 * Manages one Camera2 session per open camera.
 *
 * GPU preview path: camera → Flutter SurfaceTexture → Texture(textureId) widget.
 * Zero EGL overhead, zero CPU copy. setRepeatingRequest fires as fast as the sensor allows.
 *
 * CPU frame path: opt-in via [frameProcessingEnabled]. Delivers YUV frames to [onFrame].
 */
@SuppressLint("MissingPermission")
class NitraCameraSession(
    private val context: Context,
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    val textureId: Long,
    private val cameraDevice: AndroidCameraDevice,
    private val width: Int,
    private val height: Int,
    private val requestedFps: Int,
    private val enableAudio: Boolean,
) {
    private val cameraThread = HandlerThread("NitraSession-$textureId").also { it.start() }
    val cameraHandler = Handler(cameraThread.looper)

    // Dedicated GL Rendering thread to prevent camera controls from blocking the preview
    private val glThread = HandlerThread("NitraGLThread").apply { start() }
    private val glHandler = Handler(glThread.looper)

    // GPU Filtering Path: Camera -> Renderer -> Flutter
    private val renderer = NitraRenderer(width, height)

    // This is the surface we Hand off to the camera
    private val previewSurface: Surface by lazy {
        renderer.inputSurface ?: throw IllegalStateException("Renderer not ready")
    }

    init {
        val latch = java.util.concurrent.CountDownLatch(1)
        glHandler.post {
            try {
                // Ensure we use the surface texture correctly. 
                // We wrap it in a Surface only when needed and release it later.
                renderer.setup(Surface(textureEntry.surfaceTexture().apply { 
                    setDefaultBufferSize(width, height) 
                }))
            } finally {
                latch.countDown()
            }
        }
        // Wait for GL thread to finish setup to avoid NullPointerException in camera startup
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
    }

    @Volatile private var isClosed = false
    @Volatile private var captureSession: CameraCaptureSession? = null

    // Buffer reference for lifecycle management
    private val surfaceTexture: SurfaceTexture? by lazy {
        renderer.inputSurfaceTexture
    }

    // CPU frame path
    var frameProcessingEnabled = false
    var onFrame: ((CameraFrame) -> Unit)? = null
    private val frameReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2)

    private val characteristics: CameraCharacteristics by lazy {
        (context.getSystemService(Context.CAMERA_SERVICE) as CameraManager)
            .getCameraCharacteristics(cameraDevice.id)
    }

    val mediaManager = NitraMediaManager(
        context, cameraDevice, characteristics, cameraHandler, width, height, enableAudio
    )

    // ---- FPS ----------------------------------------------------------------

    /**
     * Returns the best available FPS range.
     * Picks the range whose upper bound is closest to (and at least) [requestedFps].
     * If requestedFps <= 0, picks the highest upper bound available.
     */
    private fun bestFpsRange(): android.util.Range<Int>? {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?: return null
        return if (requestedFps <= 0) {
            ranges.maxByOrNull { it.upper }
        } else {
            // prefer fixed range (lower == upper) at or above target; else closest matching
            ranges.filter { it.upper >= requestedFps }
                .minByOrNull { it.upper - requestedFps + if (it.lower == it.upper) 0 else 1 }
                ?: ranges.maxByOrNull { it.upper }
        }
    }

    // ---- Lifecycle ----------------------------------------------------------

    fun startPreview() {
        if (isClosed) return
        val surfaces = mutableListOf(previewSurface, mediaManager.photoReader.surface)
        if (frameProcessingEnabled) surfaces.add(frameReader.surface)

        try {
            cameraDevice.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (isClosed) { session.close(); return }
                        captureSession = session
                        sendPreviewRequest(session)
                        Log.d("NitroCamera", "Preview started on texture $textureId fps=${bestFpsRange()}")
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e("NitroCamera", "Preview session config failed for texture $textureId")
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
        
        // 1. Hook up the frame-available listener to the dedicated GL thread
        // Defensive check: ensure renderer is initialized
        val inputST = renderer.inputSurfaceTexture ?: return
        
        // Clear old listener first to avoid stray frames
        inputST.setOnFrameAvailableListener(null)
        
        inputST.setOnFrameAvailableListener({
            glHandler.post {
                if (!isClosed) {
                    try {
                        renderer.drawFrame()
                    } catch (e: Exception) {
                        Log.e("NitroCamera", "Render error: ${e.message}")
                    }
                }
            }
        }, glHandler)

        try {
            val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            bestFpsRange()?.let { range ->
                builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
            }
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "setRepeatingRequest failed: ${e.message}")
        }
    }

    fun stopPreview() {
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
    }

    suspend fun close() {
        if (isClosed) return
        isClosed = true
        
        // Wait a tiny bit to avoid hardware race conditions during sensor switching
        kotlinx.coroutines.delay(100)
        
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null
        try { cameraDevice.close() } catch (_: Exception) {}
        try { previewSurface.release() } catch (_: Exception) {}
        try { renderer.inputSurfaceTexture?.release() } catch (_: Exception) {}
        try { frameReader.close() } catch (_: Exception) {}
        mediaManager.release()
        
        // 1. FAST CLEANUP: We wait briefly (150ms) for the GPU to drain its queue.
        // We use postAtFrontOfQueue to jump ahead of frame-draw tasks.
        val releaseLatch = java.util.concurrent.CountDownLatch(1)
        glHandler.postAtFrontOfQueue {
            try {
                renderer.release()
            } finally {
                glThread.quitSafely()
                releaseLatch.countDown()
            }
        }
        
        // Wait for GL cleanup (timeout is a safety measure)
        if (!releaseLatch.await(150, java.util.concurrent.TimeUnit.MILLISECONDS)) {
            Log.w("NitroCamera", "GL cleanup timed out, Proceeding with switch...")
        }
        
        // 2. Flutter texture unregistration MUST happen on the Main thread
        withContext(Dispatchers.Main) { 
            try { textureEntry.release() } catch (_: Exception) {}
        }
        cameraThread.quitSafely()
    }

    // ---- Camera controls (all non-blocking, dispatched to cameraHandler) ---

    fun setZoom(zoom: Double) = updateRepeating { builder ->
        val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            ?: return@updateRepeating
        val maxZoom = (characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        val clamped = zoom.coerceIn(1.0, maxZoom).toFloat()
        val cx = rect.width() / 2; val cy = rect.height() / 2
        val dx = (rect.width() / (2 * clamped)).toInt()
        val dy = (rect.height() / (2 * clamped)).toInt()
        builder.set(CaptureRequest.SCALER_CROP_REGION, Rect(cx - dx, cy - dy, cx + dx, cy + dy))
    }

    fun setFocusPoint(x: Double, y: Double) {
        if (isClosed) return
        val session = captureSession ?: return
        cameraHandler.post {
            if (isClosed) return@post
            try {
                val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
                    ?: return@post
                val fx = (x * rect.width()).toInt().coerceIn(100, rect.width() - 100)
                val fy = (y * rect.height()).toInt().coerceIn(100, rect.height() - 100)
                val metering = MeteringRectangle(
                    Rect(fx - 100, fy - 100, fx + 100, fy + 100),
                    MeteringRectangle.METERING_WEIGHT_MAX
                )
                val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_PREVIEW)
                builder.addTarget(previewSurface)
                builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(metering))
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
                session.capture(builder.build(), null, cameraHandler)
            } catch (e: Exception) { Log.w("NitroCamera", "setFocusPoint: ${e.message}") }
        }
    }

    fun setAutoFocus(mode: Long) = updateRepeating { builder ->
        val afMode = when (mode) {
            0L   -> CaptureRequest.CONTROL_AF_MODE_OFF
            2L   -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            else -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
        }
        builder.set(CaptureRequest.CONTROL_AF_MODE, afMode)
    }

    fun setExposure(value: Double) = updateRepeating { builder ->
        val range = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
            ?: return@updateRepeating
        val step = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toDouble() ?: 1.0
        val ev = if (step == 0.0) 0 else (value / step).toInt().coerceIn(range.lower, range.upper)
        builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, ev)
    }

    fun setFlash(mode: Long) = updateRepeating { builder ->
        val aeMode = when (mode) {
            1L   -> CaptureRequest.CONTROL_AE_MODE_ON_ALWAYS_FLASH
            2L   -> CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH
            else -> CaptureRequest.CONTROL_AE_MODE_ON
        }
        builder.set(CaptureRequest.CONTROL_AE_MODE, aeMode)
    }

    fun setTorch(enabled: Boolean) = updateRepeating { builder ->
        builder.set(
            CaptureRequest.FLASH_MODE,
            if (enabled) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF,
        )
    }

    fun setWhiteBalance(temperature: Long) = updateRepeating { builder ->
        if (temperature == 0L) {
            builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
        } else {
            builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_OFF)
        }
    }

    fun setHdr(enabled: Boolean) = updateRepeating { builder ->
        if (enabled) {
            builder.set(CaptureRequest.CONTROL_SCENE_MODE, CaptureRequest.CONTROL_SCENE_MODE_HDR)
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_USE_SCENE_MODE)
        } else {
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
        }
    }

    /** Applies a new repeating request on [cameraHandler], preserving the current template. */
    private fun updateRepeating(configure: (CaptureRequest.Builder) -> Unit) {
        if (isClosed) return
        cameraHandler.post {
            val session = captureSession ?: return@post
            if (isClosed) return@post
            try {
                val template = if (mediaManager.isRecording)
                    AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW
                val builder = cameraDevice.createCaptureRequest(template)
                builder.addTarget(previewSurface)
                configure(builder)
                session.setRepeatingRequest(builder.build(), null, cameraHandler)
            } catch (e: Exception) {
                Log.w("NitroCamera", "updateRepeating: ${e.message}")
            }
        }
    }

    // ---- Photo / Video -------------------------------------------------------

    suspend fun takePhoto() = mediaManager.takePhoto(captureSession)

    fun startVideoRecording(outputPath: String) {
        if (isClosed) return
        cameraHandler.post {
            if (isClosed) return@post
            try {
                val recSurface = mediaManager.prepareVideoRecorder(outputPath)
                val surfaces = mutableListOf(previewSurface, recSurface, mediaManager.photoReader.surface)
                cameraDevice.createCaptureSession(
                    surfaces,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            if (isClosed) { session.close(); return }
                            captureSession = session
                            try {
                                val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_RECORD)
                                builder.addTarget(previewSurface)
                                builder.addTarget(recSurface)
                                session.setRepeatingRequest(builder.build(), null, cameraHandler)
                                mediaManager.startVideoRecorder()
                            } catch (e: Exception) {
                                Log.e("NitroCamera", "Record request failed: ${e.message}")
                            }
                        }
                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            Log.e("NitroCamera", "Record session config failed")
                            mediaManager.stopVideoRecording()
                        }
                    },
                    cameraHandler,
                )
            } catch (e: Exception) {
                Log.e("NitroCamera", "startVideoRecording: ${e.message}")
            }
        }
    }

    fun stopVideoRecording(): RecordingResult {
        try { captureSession?.stopRepeating() } catch (e: Exception) { /* Silent */ }
        try { captureSession?.close() } catch (e: Exception) { /* Silent */ }
        captureSession = null
        val result = mediaManager.stopVideoRecording()
        if (!isClosed) cameraHandler.postDelayed({ if (!isClosed) startPreview() }, 150)
        return result
    }

    fun pauseVideoRecording()  { mediaManager.pauseVideoRecording() }
    fun resumeVideoRecording() { mediaManager.resumeVideoRecording() }

    fun cancelVideoRecording() {
        val outputPath = mediaManager.recordingOutputPath
        stopVideoRecording()
        if (outputPath.isNotEmpty()) {
            try { java.io.File(outputPath).delete() } catch (_: Exception) {}
        }
    }

    // ---- Shader / overlay (no-op stubs; full GL path can be added later) ----

    fun setFrameFormat(format: Long) { /* placeholder */ }
    fun setFilterShader(shader: String) {
        cameraHandler.post {
            renderer.updateShader(shader)
        }
    }

    // ---- Frame delivery ------------------------------------------------------

    private fun emitFrame(image: android.media.Image) {
        val cb = onFrame ?: return
        try {
            val plane = image.planes[0]
            val src = plane.buffer
            val size = src.remaining().toLong()
            val copy = ByteBuffer.allocateDirect(src.remaining())
            copy.put(src)
            copy.rewind()
            cb(CameraFrame(copy, size, image.width.toLong(), image.height.toLong(),
                System.currentTimeMillis(), 0L, textureId))
        } catch (e: Exception) {
            Log.w("NitroCamera", "emitFrame: ${e.message}")
        }
    }
}
