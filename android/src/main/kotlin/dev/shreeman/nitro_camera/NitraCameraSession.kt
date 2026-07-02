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
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import android.hardware.camera2.CameraManager

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
    private var cameraDevice: AndroidCameraDevice,
    private val characteristics: CameraCharacteristics,
    private val deviceId: String,
    private val width: Int,
    private val height: Int,
    private val requestedFps: Int,
    private val enableAudio: Boolean,
) {
    private val cameraThread = HandlerThread("NitraSession-$textureId").also { it.start() }
    val cameraHandler = Handler(cameraThread.looper)

    private val glThread = HandlerThread("NitraGLThread").apply { start() }
    private val glHandler = Handler(glThread.looper)

    private val resolvedSize: android.util.Size = run {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw IllegalStateException("No stream configuration map")
        val sizes = map.getOutputSizes(SurfaceTexture::class.java)

        // Find size that matches requested aspect ratio best, or closest matching size.
        // (The preview STRETCH is fixed on the Flutter side — the native GL renderer
        // already center-crops — so we keep this proven selection to avoid breaking
        // the device's supported stream combination.)
        val targetAspect = width.toFloat() / height.toFloat()

        sizes.minByOrNull { s ->
            val aspect = s.width.toFloat() / s.height.toFloat()
            val aspectDiff = Math.abs(aspect - targetAspect)
            val areaDiff = Math.abs(s.width * s.height - width * height)
            aspectDiff * 1000000 + areaDiff
        } ?: sizes[0]
    }

    private val renderer = NitraRenderer(resolvedSize.width, resolvedSize.height)

    private var previewSurface: Surface? = null
    private var currentRequestBuilder: CaptureRequest.Builder? = null

    // --- Persistent Camera State ---
    private var zoomValue: Double = 1.0
    private var flashMode: Long = 0L
    private var exposureValue: Double = 0.0
    private var afMode: Long = 1L
    private var torchEnabled: Boolean = false
    private var torchLevel: Double = 1.0
    private var videoStabMode: Long = 0L
    private var lowLightBoost: Boolean = false
    private var aeLocked: Boolean = false
    private var awbLocked: Boolean = false
    private var afLocked: Boolean = false
    private var targetOrientationDeg: Int = -1
    private var whiteBalanceKelvin: Long = 0L
    private var hdrEnabled: Boolean = false

    // --- Read-back accessors (used by configure()/getSessionStateJson) ---
    val streamWidth: Int get() = resolvedSize.width
    val streamHeight: Int get() = resolvedSize.height
    val activeFps: Int get() = bestFpsRange()?.upper ?: requestedFps
    val currentPixelFormat: Long get() = pixelFormat
    val isPreviewRunning: Boolean get() = captureSession != null

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
                renderer.setSensorOrientation(characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90)
                val isFront = characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
                renderer.setIsFrontCamera(isFront)
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
    var onEvent: ((CameraEventType, InterruptionReason, String) -> Unit)? = null
    private var pixelFormat: Long = 1
    private var samplingRate: Long = 1
    private var frameCounter: Long = 0
    private val frameReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2)
    private var directBuffer: ByteBuffer? = null
    private var lastRawShader: String = ""

    val mediaManager = NitraMediaManager(
        context, cameraDevice, characteristics, cameraHandler, width, height, enableAudio
    )

    fun onAppStop() {
        if (isClosed) return
        try {
            captureSession?.stopRepeating()
            captureSession?.close()
        } catch (_: Exception) {}
        captureSession = null
        try {
            cameraDevice.close()
        } catch (_: Exception) {}
        onEvent?.invoke(
            CameraEventType.INTERRUPTIONSTARTED,
            InterruptionReason.VIDEODEVICENOTAVAILABLEINBACKGROUND,
            "",
        )
        Log.d("NitroCamera", "Session $textureId paused hardware")
    }

    suspend fun onAppResume(cameraManager: CameraManager) {
        if (isClosed) return
        if (captureSession != null) return // Already running

        Log.d("NitroCamera", "Session $textureId resuming hardware for $deviceId")
        try {
            val newDevice = suspendCancellableCoroutine<AndroidCameraDevice> { cont ->
                try {
                    cameraManager.openCamera(deviceId, object : AndroidCameraDevice.StateCallback() {
                        override fun onOpened(cam: AndroidCameraDevice) {
                            if (cont.isActive) cont.resume(cam)
                        }
                        override fun onDisconnected(cam: AndroidCameraDevice) {
                            cam.close()
                            if (cont.isActive) cont.cancel()
                        }
                        override fun onError(cam: AndroidCameraDevice, error: Int) {
                            cam.close()
                            if (cont.isActive) cont.resumeWith(Result.failure(Exception("Camera resume error $error")))
                        }
                    }, cameraHandler)
                } catch (e: Exception) {
                    if (cont.isActive) cont.resumeWith(Result.failure(e))
                }
            }
            this.cameraDevice = newDevice
            startPreview()
            onEvent?.invoke(CameraEventType.INTERRUPTIONENDED, InterruptionReason.NONE, "")
        } catch (e: Exception) {
            Log.e("NitroCamera", "Failed to resume session $textureId: ${e.message}")
            onEvent?.invoke(
                CameraEventType.ERROR,
                InterruptionReason.NONE,
                "Failed to resume session: ${e.message}",
            )
        }
    }

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
        
        // Sync buffer size
        renderer.inputSurfaceTexture?.setDefaultBufferSize(resolvedSize.width, resolvedSize.height)

        val surfaces = mutableListOf(pSurface, mediaManager.photoReader.surface, frameReader.surface)

        try {
            cameraDevice.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (isClosed) { session.close(); return }
                        captureSession = session
                        sendPreviewRequest(session)
                        onEvent?.invoke(CameraEventType.STARTED, InterruptionReason.NONE, "")
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e("NitroCamera", "Preview session config failed")
                        onEvent?.invoke(
                            CameraEventType.ERROR,
                            InterruptionReason.NONE,
                            "Preview session configuration failed",
                        )
                    }
                },
                cameraHandler,
            )
        } catch (e: Exception) {
            Log.e("NitroCamera", "createCaptureSession failed: ${e.message}")
        }

        frameReader.setOnImageAvailableListener({ reader ->
            if (isClosed) return@setOnImageAvailableListener
            
            // ALWAYS acquire and close the image to free the buffer pool,
            // even if processing is currently disabled.
            val image = try { reader.acquireLatestImage() } catch (_: Exception) { null }
                ?: return@setOnImageAvailableListener

            try { 
                if (frameProcessingEnabled) {
                    emitFrame(image)
                }
            } finally {
                image.close()
            }
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
            currentRequestBuilder = builder
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
        val af = when {
            afLocked      -> CaptureRequest.CONTROL_AF_MODE_OFF
            afMode == 0L  -> CaptureRequest.CONTROL_AF_MODE_OFF
            afMode == 2L  -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            else          -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
        }
        builder.set(CaptureRequest.CONTROL_AF_MODE, af)

        // White balance (temperature → nearest supported preset) + 3A locks.
        val awbModes = characteristics.get(
            CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES
        ) ?: intArrayOf()
        val awb = awbModeFor(whiteBalanceKelvin)
        builder.set(
            CaptureRequest.CONTROL_AWB_MODE,
            if (awbModes.contains(awb)) awb else CaptureRequest.CONTROL_AWB_MODE_AUTO,
        )
        builder.set(CaptureRequest.CONTROL_AE_LOCK, aeLocked)
        builder.set(CaptureRequest.CONTROL_AWB_LOCK, awbLocked)

        // Video stabilization (falls back to OFF when the requested mode is
        // unsupported by the device).
        val stabModes = characteristics.get(
            CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES
        ) ?: intArrayOf()
        val stab = if (videoStabMode != 0L &&
            stabModes.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)) {
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON
        } else {
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF
        }
        builder.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, stab)

        // Handle Flash/Torch logic
        if (torchEnabled) {
            builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        } else {
            val availableAeModes = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES) ?: intArrayOf()
            var ae = CaptureRequest.CONTROL_AE_MODE_ON
            
            when (flashMode) {
                1L -> { // FLASH ON
                    if (availableAeModes.contains(CaptureRequest.CONTROL_AE_MODE_ON_ALWAYS_FLASH)) {
                        ae = CaptureRequest.CONTROL_AE_MODE_ON_ALWAYS_FLASH
                        builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF) // AE handles it
                    } else {
                        ae = CaptureRequest.CONTROL_AE_MODE_ON
                        builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_SINGLE)
                    }
                }
                2L -> { // FLASH AUTO
                    if (availableAeModes.contains(CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH)) {
                        ae = CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH
                        builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF) // AE handles it
                    }
                }
                else -> { // FLASH OFF
                    ae = CaptureRequest.CONTROL_AE_MODE_ON
                    builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
                    // Ensure we reset any pending precapture sequences that might hold the flash
                    builder.set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER, CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER_CANCEL)
                }
            }
            builder.set(CaptureRequest.CONTROL_AE_MODE, ae)
        }
        // Always reset trigger to idle in repeating request after cancel/start if we don't want it to keep firing
        // However, setting it to NULL or not setting it is better for repeating requests.
        // Actually, we should only set it in the capture(builder.build()) for one-shot.
        // So I'll ensure it's IDLE here for the repeating preview.
        builder.set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER, CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER_IDLE)


        val zoomSet = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val zoomRange = characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
            if (zoomRange != null) {
                val clamped = zoomValue.toFloat().coerceIn(zoomRange.lower, zoomRange.upper)
                builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, clamped)
                true
            } else false
        } else false

        if (!zoomSet) {
            val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            if (rect != null) {
                val maxZ = (characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
                val clamped = zoomValue.coerceIn(1.0, maxZ).toFloat()
                val cx = rect.width() / 2; val cy = rect.height() / 2
                val dx = (rect.width() / (2 * clamped)).toInt()
                val dy = (rect.height() / (2 * clamped)).toInt()
                builder.set(CaptureRequest.SCALER_CROP_REGION, android.graphics.Rect(cx - dx, cy - dy, cx + dx, cy + dy))
            }
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
        onEvent?.invoke(CameraEventType.STOPPED, InterruptionReason.NONE, "")

        // 1. DETACH from Flutter immediately on Main thread to prevent new frames from scheduling
        withContext(Dispatchers.Main) {
            try {
               val producer = (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)
               producer?.setCallback(null)
               // Note: We don't release yet, just detach the listener
            } catch (_: Exception) {}
        }

        // 2. CLEAR CALLBACKS to stop internal frame delivery
        try {
            renderer.inputSurfaceTexture?.setOnFrameAvailableListener(null)
            previewSurface?.let { if (it.isValid) it.release() }
            previewSurface = null
        } catch (_: Exception) {}

        // 3. Tear down hardware synchronously to stop the stream
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null
        try { cameraDevice.close() } catch (_: Exception) {}
        try { frameReader.close() } catch (_: Exception) {}
        mediaManager.release()

        val releaseLatch = java.util.concurrent.CountDownLatch(1)
        if (glHandler.looper.thread.isAlive) {
            glHandler.postAtFrontOfQueue {
                try { 
                    renderer.release() 
                } catch (_: Exception) {
                } finally {
                    glThread.quitSafely()
                    releaseLatch.countDown()
                }
            }
            try { releaseLatch.await(500, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: Exception) {}
        } else {
            releaseLatch.countDown()
        }

        withContext(Dispatchers.Main) {
            surfaceEntry?.release()
            try {
               val producer = (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)
               producer?.release()
            } catch (_: Exception) {}
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
            val builder = currentRequestBuilder ?: return@post
            if (isClosed) return@post
            try {
                // Reuse cached builder to avoid expensive createCaptureRequest overhead
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

    /// White balance by colour temperature (Kelvin). 0 = auto. Maps the
    /// temperature to the nearest device-supported `CONTROL_AWB_MODE` preset
    /// (falls back to AUTO when the preset is unavailable).
    fun setWhiteBalance(temperature: Long) { whiteBalanceKelvin = temperature; triggerUpdate() }

    /// HDR still capture. Real 10-bit HDR *video* needs a DynamicRangeProfile at
    /// session creation; here we enable the HDR scene mode on the still-capture
    /// request only, so the preview 3A pipeline is left untouched.
    fun setHdr(enabled: Boolean) { hdrEnabled = enabled }

    private fun awbModeFor(kelvin: Long): Int = when {
        kelvin <= 0L    -> CaptureRequest.CONTROL_AWB_MODE_AUTO
        kelvin < 3200L  -> CaptureRequest.CONTROL_AWB_MODE_INCANDESCENT
        kelvin < 4000L  -> CaptureRequest.CONTROL_AWB_MODE_WARM_FLUORESCENT
        kelvin < 5000L  -> CaptureRequest.CONTROL_AWB_MODE_FLUORESCENT
        kelvin < 5800L  -> CaptureRequest.CONTROL_AWB_MODE_DAYLIGHT
        kelvin < 7000L  -> CaptureRequest.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
        else            -> CaptureRequest.CONTROL_AWB_MODE_TWILIGHT
    }

    fun setVideoStabilization(mode: Long) { videoStabMode = mode; triggerUpdate() }
    fun setLowLightBoost(enabled: Boolean) { lowLightBoost = enabled; triggerUpdate() }
    fun lockExposure(locked: Boolean) { aeLocked = locked; triggerUpdate() }
    fun lockWhiteBalance(locked: Boolean) { awbLocked = locked; triggerUpdate() }
    fun lockFocus(locked: Boolean) { afLocked = locked; triggerUpdate() }
    fun setTargetOrientation(degrees: Int) { targetOrientationDeg = degrees }

    fun setTorchLevel(level: Double) {
        torchLevel = level.coerceIn(0.0, 1.0)
        torchEnabled = torchLevel > 0.0
        // Per-level brightness (CameraManager.turnOnTorchWithStrengthLevel, API 33+)
        // is device-specific; here we drive the capture-request torch and keep the
        // level for future strength support.
        triggerUpdate()
    }

    fun setFrameFormat(format: Long)     { pixelFormat = format }
    fun setSamplingRate(rate: Long)     { samplingRate = rate }
    fun setFilterShader(shader: String) {
        lastRawShader = shader
        glHandler.post {
            renderer.updateShader(shader)
        }
    }

    fun attachPlatformSurface(surface: Surface?) {
        glHandler.post {
            renderer.setPlatformSurface(surface)
        }
    }

    fun detachPlatformSurface() {
        glHandler.post {
            renderer.detachPlatformSurface()
        }
    }



    suspend fun takePhoto(): PhotoResult {
        // Self-healing: the full request layers scene-mode HDR + 3A which some HALs
        // (e.g. Oplus at full res) reject with REASON_ERROR. If it fails, retry once
        // with a minimal, known-good request so a photo is still produced.
        return try {
            doCapture(useHdr = hdrEnabled, minimal = false)
        } catch (e: Exception) {
            Log.w("NitroCamera", "takePhoto failed (${e.message}); retrying minimal request")
            doCapture(useHdr = false, minimal = true)
        }
    }

    private suspend fun doCapture(useHdr: Boolean, minimal: Boolean): PhotoResult {
        val session = captureSession ?: throw Exception("No active session")

        // Stop the preview repeating request to prepare for the still capture.
        try { session.stopRepeating() } catch (_: Exception) {}

        val builder = cameraDevice.createCaptureRequest(
            android.hardware.camera2.CameraDevice.TEMPLATE_STILL_CAPTURE)
        builder.addTarget(mediaManager.photoReader.surface)

        val orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        builder.set(CaptureRequest.JPEG_ORIENTATION, orientation)

        if (minimal) {
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        } else {
            applySessionSettings(builder)
            // HDR still (scene mode) when requested + supported.
            if (useHdr) {
                val sceneModes = characteristics.get(
                    CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES) ?: intArrayOf()
                if (sceneModes.contains(CaptureRequest.CONTROL_SCENE_MODE_HDR)) {
                    builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_USE_SCENE_MODE)
                    builder.set(CaptureRequest.CONTROL_SCENE_MODE, CaptureRequest.CONTROL_SCENE_MODE_HDR)
                }
            }
            // Manual Flash 'ON' → AE precapture so the flash fires.
            if (flashMode == 1L) {
                builder.set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER,
                    CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER_START)
            }
        }

        return mediaManager.takePhotoWithRequest(
            session = session,
            request = builder.build(),
            renderer = renderer,
            shader = lastRawShader ?: "",
        ) {
            // Resume the preview repeating request after capture.
            cameraHandler.post { triggerUpdate() }
        }
    }

    suspend fun startVideoRecording(outputPath: String, options: RecordingOptions) {
        if (isClosed) throw IllegalStateException("Camera session is closed")
        // Auto-stop (maxDuration/maxFileSize) → finalise + emit a `stopped` event
        // carrying the path (no pending stopVideoRecording call in that path).
        mediaManager.onMaxReached = {
            glHandler.post { renderer.setRecordingSurface(null) }
            val result = mediaManager.stopVideoRecording()
            onEvent?.invoke(CameraEventType.STOPPED, InterruptionReason.NONE, result.path)
        }
        // Await the cameraHandler result so a MediaRecorder prepare/start failure
        // propagates to the caller (Dart) instead of being silently swallowed.
        suspendCancellableCoroutine { cont ->
            cameraHandler.post {
                if (isClosed) {
                    if (cont.isActive) cont.resumeWith(Result.failure(IllegalStateException("Camera session is closed")))
                    return@post
                }
                try {
                    // 1. Prepare recorder + surface (throws if the encoder rejects the config)
                    val recSurface = mediaManager.prepareVideoRecorder(
                        outputPath,
                        codec = options.codec.toInt(),
                        bitRate = options.bitRate.toInt(),
                        maxDurationMs = options.maxDurationMs.toInt(),
                        maxFileSizeBytes = options.maxFileSizeBytes,
                        lat = options.latitude,
                        lon = options.longitude,
                        hasLocation = options.hasLocation != 0L,
                    )
                    // 2. Start the hardware recorder FIRST (important for some drivers)
                    mediaManager.startVideoRecorder()
                    // 3. Enable the surface on the GL thread ONLY after the recorder is active
                    glHandler.post { renderer.setRecordingSurface(recSurface) }
                    Log.d("NitroCamera", "Video recording started on GPU pipeline")
                    if (cont.isActive) cont.resume(Unit)
                } catch (e: Exception) {
                    Log.e("NitroCamera", "startVideoRecording failed: ${e.message}")
                    onEvent?.invoke(
                        CameraEventType.ERROR,
                        InterruptionReason.NONE,
                        "startVideoRecording failed: ${e.message}",
                    )
                    if (cont.isActive) cont.resumeWith(Result.failure(e))
                }
            }
        }
    }

    fun stopVideoRecording(): RecordingResult {
        // 1. Block until GL thread has finished the last frame and detached the surface
        val latch = java.util.concurrent.CountDownLatch(1)
        glHandler.post {
            renderer.setRecordingSurface(null)
            latch.countDown()
        }
        try { latch.await(200, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: Exception) {}

        // 2. Now safe to stop the actual recorder
        return mediaManager.stopVideoRecording()
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
            // The frame reader delivers YUV_420_888; plane[0] is the luma plane,
            // whose row stride (`rowStride`) may exceed width due to alignment.
            val isFront = characteristics.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_FRONT

            cb(CameraFrame(buffer, size, image.width.toLong(), image.height.toLong(),
                System.currentTimeMillis(), rotation.toLong(), textureId,
                plane.rowStride.toLong(), 0L /* YUV luma */, if (isFront) 1L else 0L))
        } catch (_: Exception) { }
    }
}
