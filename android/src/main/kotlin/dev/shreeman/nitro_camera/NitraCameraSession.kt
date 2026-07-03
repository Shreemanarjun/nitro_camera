package dev.shreeman.nitro_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.hardware.camera2.params.MeteringRectangle
import android.hardware.display.DisplayManager
import android.view.Display
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
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
    val deviceId: String,
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

    // Keep the preview's content rotation in sync with the device orientation so it
    // stays upright in portrait AND landscape (like the stock camera).
    private val displayManager =
        context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayChanged(displayId: Int) {
            // A manual setTargetOrientation lock wins over display-following.
            if (targetOrientationDeg < 0) {
                renderer.displayRotationDegrees = currentDisplayRotationDegrees()
            }
        }
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
    }

    /**
     * Configure GPU barrel-undistortion for this lens so the preview matches the
     * stock camera (which undistorts the ultra-wide). Prefers the device's own
     * LENS_DISTORTION calibration; falls back to a tuned default for uncalibrated
     * ultra-wides (FOV > 90°); leaves normal/tele lenses untouched (K = 0).
     */
    private fun configureDistortion() {
        try {
            val preArr = characteristics.get(
                CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE)
            val intr = characteristics.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
            val dist = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                characteristics.get(CameraCharacteristics.LENS_DISTORTION) else null

            // focal length / buffer width (isotropic). Prefer intrinsics, else derive
            // from focal length + physical sensor width.
            var focalN = 0f
            if (intr != null && intr.isNotEmpty() && preArr != null && preArr.width() > 0) {
                focalN = intr[0] / preArr.width().toFloat()
            } else {
                val focals = characteristics.get(
                    CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                val phys = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                val f = focals?.minOrNull()
                if (f != null && phys != null && phys.width > 0f) focalN = f / phys.width
            }
            if (focalN <= 0.01f) { renderer.setDistortion(0f, 0f, 0f, 0.5f); return }

            val hfovDeg = Math.toDegrees(2.0 * Math.atan(1.0 / (2.0 * focalN)))
            when {
                dist != null && dist.size >= 3 && (dist[0] != 0f || dist[1] != 0f) ->
                    renderer.setDistortion(dist[0], dist[1], dist[2], focalN)
                hfovDeg > 90.0 ->
                    // Uncalibrated ultra-wide → mild barrel correction (negative k1
                    // pulls the bulging edges straight without over-correcting).
                    renderer.setDistortion(-0.12f, 0.0f, 0f, focalN)
                else ->
                    renderer.setDistortion(0f, 0f, 0f, focalN)
            }
            Log.d("NitroCamera", "configureDistortion: hfov=${hfovDeg.toInt()}° focalN=$focalN dist=${dist?.joinToString()}")
        } catch (_: Exception) {
            renderer.setDistortion(0f, 0f, 0f, 0.5f)
        }
    }

    private fun currentDisplayRotationDegrees(): Int {
        val rotation = try {
            displayManager.getDisplay(Display.DEFAULT_DISPLAY)?.rotation ?: Surface.ROTATION_0
        } catch (_: Exception) {
            Surface.ROTATION_0
        }
        return when (rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }

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
    // Default ON: without it the ultra-wide shows heavy barrel distortion.
    private var distortionCorrection: Boolean = true
    // Active native ML detector ("barcode" / "face" / "" = off).
    @Volatile private var nativeDetector: String = ""

    // Whether this camera has a physical flash unit (front sensors usually
    // don't). Gates every FLASH_MODE / AE-flash-mode request — flash-less HALs
    // ignore or reject them — and routes flash≠off captures to the screen-fill
    // path in doCapture instead.
    private val hasFlashUnit: Boolean =
        characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true

    private companion object {
        /// Max wait for the AE precapture sequence to settle before capturing anyway.
        const val PRECAPTURE_TIMEOUT_MS = 1_500L

        /// Screen-fill flash (flash-less front cameras): time given to the white
        /// overlay + max-brightness window to actually light the subject (and AE
        /// to react) before the exposure starts.
        const val SCREEN_FLASH_ILLUMINATION_MS = 350L
    }

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

        // Seed + track device rotation for an upright preview in all orientations.
        renderer.displayRotationDegrees = currentDisplayRotationDegrees()
        try { displayManager.registerDisplayListener(displayListener, cameraHandler) } catch (_: Exception) {}

        // Configure lens undistortion (corrects the ultra-wide's barrel distortion).
        configureDistortion()

        // Listen to SurfaceProducer lifecycle if available. Flutter recreates the
        // producer surface on rotation/layout — that must ONLY rebind the EGL
        // window surface, never stop/start the camera (a full preview restart on
        // every rotation showed as the preview being "recreated").
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && surfaceProducer != null) {
            val producer = surfaceProducer as io.flutter.view.TextureRegistry.SurfaceProducer
            producer.setCallback(object : io.flutter.view.TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    glHandler.post {
                        renderer.setFlutterSurface(producer.getSurface())
                        // First-ever availability may precede startPreview; keep the
                        // original behaviour of kicking the preview if it isn't up.
                        if (!isPreviewRunning) startPreview()
                    }
                }

                override fun onSurfaceCleanup() {
                    glHandler.post { renderer.setFlutterSurface(null) }
                }
            })
        }
    }

    @Volatile private var isClosed = false
    @Volatile private var captureSession: CameraCaptureSession? = null

    // --- Persistent recorder surface state (instant recording start) ---
    // Non-null while a recording streams through the persistent recorder surface
    // that is pre-wired into the capture session (no reconfiguration at start).
    @Volatile private var recordingViaSessionSurface: Surface? = null
    // Set when the device rejects the extra recorder stream at session config;
    // from then on this session records via the GL pipeline fallback only.
    @Volatile private var persistentSurfaceUnusable = false
    // Whether the CURRENT capture session was configured with the recorder surface.
    @Volatile private var persistentSurfaceInSession = false

    // @Volatile: written from the Dart/nitro thread, read per-frame on the
    // camera thread (frameReader listener + sendPreviewRequest) — a stale
    // `false` there silently drops scanner frames.
    @Volatile var frameProcessingEnabled = false
        set(value) {
            if (field != value) {
                field = value
                // Rebuild ON THE CAMERA THREAD — this setter is called from the
                // Dart/nitro thread, and sendPreviewRequest must never race the
                // cameraHandler-based rebuilds (session config, detector toggle,
                // recording start/stop). Skip during session bring-up: the
                // initial sendPreviewRequest reads this flag itself.
                cameraHandler.post {
                    val session = captureSession ?: return@post
                    if (currentRequestBuilder == null) return@post
                    if (!isClosed) sendPreviewRequest(session)
                }
            }
        }
    var onFrame: ((CameraFrame) -> Unit)? = null
    var onEvent: ((CameraEventType, InterruptionReason, String) -> Unit)? = null
    // @Volatile: set from the Dart/nitro thread (setFrameFormat/setSamplingRate),
    // read on the camera thread (emitFrame / state read-back).
    @Volatile private var pixelFormat: Long = 1
    @Volatile private var samplingRate: Long = 1
    private var frameCounter: Long = 0

    // Frame-processing (scanner) YUV stream size — MUST be a size the camera
    // actually advertises for YUV_420_888, otherwise the HAL may accept the
    // session and then never deliver a single buffer. Prefers the requested
    // size when supported, else the closest supported size by area.
    private val frameReaderSize: android.util.Size = run {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val yuvSizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
        when {
            yuvSizes == null || yuvSizes.isEmpty() -> android.util.Size(width, height)
            yuvSizes.any { it.width == width && it.height == height } ->
                android.util.Size(width, height)
            else -> yuvSizes.minByOrNull {
                Math.abs(it.width.toLong() * it.height - width.toLong() * height)
            }!!
        }
    }
    private val frameReader = ImageReader.newInstance(
        frameReaderSize.width, frameReaderSize.height, ImageFormat.YUV_420_888, 2)

    /**
     * Whether the persistent recorder surface may be pre-wired into the capture
     * session as a 4th stream (PRIV preview + JPEG photo + YUV frameReader +
     * PRIV recorder). That combination is NOT in any guaranteed
     * stream-combination table — even LEVEL_3 only guarantees the second PRIV
     * stream at VGA — so it only works by OEM grace. Some HALs accept it at
     * configure time and then silently STARVE one stream: on the OnePlus
     * CPH2447 front camera the session configures, the preview runs, but the
     * YUV frameReader never receives a single buffer (scanner stuck at
     * 0 FPS; dumpsys shows "Frames produced: 0" with all HAL buffers dequeued
     * and every in-flight request stuck at "buffers left: 1").
     *
     * So the recorder surface is only pre-wired where it is known-good: BACK
     * cameras on FULL/LEVEL_3 hardware. Front and limited cameras record via
     * the GL-pipeline fallback instead (slightly slower start, still works),
     * and the frameReader is ALWAYS part of the session.
     */
    private val canPreWireRecorderSurface: Boolean = run {
        val isFront = characteristics.get(CameraCharacteristics.LENS_FACING) ==
            CameraCharacteristics.LENS_FACING_FRONT
        val level = characteristics.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
        !isFront && (level == CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL ||
            level == CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3)
    }
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

        // Already configured? Re-send the repeating request instead of calling
        // createCaptureSession again — a second createCaptureSession on a live
        // device implicitly tears the running session down and reconfigures it
        // (a multi-hundred-ms preview freeze). configure() calls startPreview()
        // on EVERY apply with active=1, so this also covers resuming after
        // stopPreview() (which only stops the repeating request).
        val existing = captureSession
        if (existing != null) {
            cameraHandler.post {
                if (!isClosed && captureSession === existing) sendPreviewRequest(existing)
            }
            return
        }

        // Ensure renderer surface is ready
        val pSurface = renderer.inputSurface ?: return
        previewSurface = pSurface
        
        // Sync buffer size
        renderer.inputSurfaceTexture?.setDefaultBufferSize(resolvedSize.width, resolvedSize.height)

        val surfaces = mutableListOf(pSurface, mediaManager.photoReader.surface, frameReader.surface)
        // Pre-wire the persistent recorder surface into the session so recordings
        // start instantly (no session reconfiguration at record time). It is NOT
        // added as a repeating-request target until a recording actually starts —
        // targeting a consumer-less surface would stall the pipeline. Only done
        // where the 4-stream combo is known-good (see canPreWireRecorderSurface);
        // if the device still rejects the extra stream we retry without it
        // (GL recording fallback).
        val recorderSurface =
            if (persistentSurfaceUnusable || !canPreWireRecorderSurface) null
            else mediaManager.acquirePersistentRecorderSurface()
        if (recorderSurface != null) surfaces.add(recorderSurface)
        val includesRecorder = recorderSurface != null

        Log.i("NitroCamera", "createCaptureSession($deviceId): " +
            "preview(PRIV)=${resolvedSize.width}x${resolvedSize.height} " +
            "photo(JPEG) frame(YUV)=${frameReaderSize.width}x${frameReaderSize.height} " +
            "recorder(PRIV)=${if (includesRecorder) "pre-wired" else "off (GL record fallback)"} " +
            "fpsRange=${bestFpsRange()}")

        try {
            cameraDevice.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (isClosed) { session.close(); return }
                        captureSession = session
                        persistentSurfaceInSession = includesRecorder
                        sendPreviewRequest(session)
                        onEvent?.invoke(CameraEventType.STARTED, InterruptionReason.NONE, "")
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        if (includesRecorder && !persistentSurfaceUnusable && !isClosed) {
                            Log.w("NitroCamera",
                                "Session config failed with recorder surface; retrying without it")
                            persistentSurfaceUnusable = true
                            startPreview()
                            return
                        }
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
            if (includesRecorder && !persistentSurfaceUnusable) {
                Log.w("NitroCamera",
                    "createCaptureSession rejected recorder surface (${e.message}); retrying without it")
                persistentSurfaceUnusable = true
                startPreview()
                return
            }
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
                val det = nativeDetector
                if (det.isNotEmpty()) {
                    // NitraDetectors copies what it needs SYNCHRONOUSLY (the
                    // image is closed right after this call) and runs the ML
                    // model async with drop-while-busy throttling.
                    NitraDetectors.process(image, characteristics, textureId, det) { json ->
                        onEvent?.invoke(CameraEventType.DETECTION, InterruptionReason.NONE, json)
                    }
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
            // While a persistent-surface recording is active the repeating request
            // must also feed the recorder (TEMPLATE_RECORD keeps the frame rate
            // stable for the encoder).
            val recordSurface = recordingViaSessionSurface
            val template = if (recordSurface != null) {
                android.hardware.camera2.CameraDevice.TEMPLATE_RECORD
            } else {
                android.hardware.camera2.CameraDevice.TEMPLATE_PREVIEW
            }
            val builder = cameraDevice.createCaptureRequest(template)
            val pSurface = previewSurface ?: return
            builder.addTarget(pSurface)
            if (recordSurface != null) builder.addTarget(recordSurface)
            if (frameProcessingEnabled || nativeDetector.isNotEmpty()) {
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
        // Lens distortion correction — WITHOUT this the ultra-wide (0.5×) shows heavy
        // barrel distortion (straight lines bulge → looks "stretched"). Stock camera
        // apps enable it; so do we by default, when the device supports it (API 28+).
        // Toggleable via setDistortionCorrection (vision-camera's
        // enableDistortionCorrection — which CameraX can't even apply on Android).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val modes = characteristics.get(
                CameraCharacteristics.DISTORTION_CORRECTION_AVAILABLE_MODES
            ) ?: intArrayOf()
            when {
                !distortionCorrection ->
                    if (modes.contains(CaptureRequest.DISTORTION_CORRECTION_MODE_OFF))
                        builder.set(CaptureRequest.DISTORTION_CORRECTION_MODE,
                            CaptureRequest.DISTORTION_CORRECTION_MODE_OFF)
                modes.contains(CaptureRequest.DISTORTION_CORRECTION_MODE_HIGH_QUALITY) ->
                    builder.set(CaptureRequest.DISTORTION_CORRECTION_MODE,
                        CaptureRequest.DISTORTION_CORRECTION_MODE_HIGH_QUALITY)
                modes.contains(CaptureRequest.DISTORTION_CORRECTION_MODE_FAST) ->
                    builder.set(CaptureRequest.DISTORTION_CORRECTION_MODE,
                        CaptureRequest.DISTORTION_CORRECTION_MODE_FAST)
            }
        }

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

        // Handle Flash/Torch logic — gated on FLASH_INFO_AVAILABLE: cameras
        // without a flash unit (typically the front sensor) ignore or reject
        // FLASH_MODE / AE flash modes, so they get plain AE. Front "flash" is
        // implemented as a screen-fill in doCapture instead.
        if (!hasFlashUnit) {
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
        } else if (torchEnabled) {
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
                    } else {
                        builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
                    }
                }
                else -> { // FLASH OFF
                    ae = CaptureRequest.CONTROL_AE_MODE_ON
                    builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
                }
            }
            builder.set(CaptureRequest.CONTROL_AE_MODE, ae)
        }
        // Keep the precapture trigger IDLE on every request built here — the
        // still-capture path drives the AE precapture sequence explicitly with
        // a one-shot TRIGGER_START frame (see runFlashPrecapture). IDLE means
        // "no change"; it does NOT cancel a running sequence.
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

    /// Full teardown: hardware + GL + media + the Flutter texture registration.
    suspend fun close() {
        closeKeepTexture()
        releaseTexture()
    }

    /// Tears down the camera hardware / GL / media pipelines but KEEPS the
    /// Flutter texture registered, so a mounted `Texture` widget keeps showing
    /// the last rendered frame (freeze-frame device switch). Callers must
    /// eventually follow up with [releaseTexture].
    suspend fun closeKeepTexture() {
        if (isClosed) return
        isClosed = true
        val closeStart = android.os.SystemClock.elapsedRealtime()
        try { displayManager.unregisterDisplayListener(displayListener) } catch (_: Exception) {}
        onEvent?.invoke(CameraEventType.STOPPED, InterruptionReason.NONE, "")

        // Stop internal frame delivery immediately (thread-safe, cheap).
        try { renderer.inputSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Exception) {}

        // The four teardown branches below are independent of each other, so
        // they run IN PARALLEL — the old serial sequence (main-thread hop →
        // hardware close → media release → GL latch → main-thread hop) is what
        // made a camera switch slow.
        coroutineScope {
            // (a) Hardware — the critical path that frees the HAL for the next
            //     open. Camera2 objects are thread-safe.
            val hardware = async(Dispatchers.IO) {
                try { captureSession?.stopRepeating() } catch (_: Exception) {}
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null
                try { cameraDevice.close() } catch (_: Exception) {}
                try { frameReader.close() } catch (_: Exception) {}
                try { previewSurface?.let { if (it.isValid) it.release() } } catch (_: Exception) {}
                previewSurface = null
            }
            // (b) GL renderer/thread.
            val gl = async(Dispatchers.IO) {
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
                    try { releaseLatch.await(250, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: Exception) {}
                }
            }
            // (c) Detector + media (recorder / persistent surface / photo reader).
            val media = async(Dispatchers.IO) {
                try { NitraDetectors.stop(textureId) } catch (_: Exception) {}
                try { mediaManager.release() } catch (_: Exception) {}
            }
            // (d) Detach the Flutter producer callback on the main thread so no
            //     new surface callbacks schedule work (release comes later).
            val flutterDetach = async(Dispatchers.Main) {
                try {
                    (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)
                        ?.setCallback(null)
                } catch (_: Exception) {}
            }
            awaitAll(hardware, gl, media, flutterDetach)
        }

        cameraThread.quitSafely()
        Log.d("NitroCamera", "Session $textureId closed in " +
            "${android.os.SystemClock.elapsedRealtime() - closeStart}ms" +
            " (texture $textureId still registered)")
    }

    @Volatile private var textureReleased = false

    /// Releases the Flutter texture registration. Idempotent. Only call after
    /// [closeKeepTexture] (every producer/consumer must already be gone).
    suspend fun releaseTexture() {
        if (textureReleased) return
        textureReleased = true
        withContext(Dispatchers.Main) {
            surfaceEntry?.release()
            try {
               val producer = (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)
               producer?.release()
            } catch (_: Exception) {}
        }
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

    /// Lens distortion correction toggle (default on; no-op below API 28 or on
    /// devices without DISTORTION_CORRECTION modes).
    fun setDistortionCorrection(enabled: Boolean) {
        distortionCorrection = enabled
        triggerUpdate()
    }

    /// Activates a native ML detector ("barcode" / "face"; "" = off). Frames
    /// start flowing to the frame reader if they weren't already, and results
    /// are emitted as DETECTION events (JSON payload).
    fun setNativeDetector(name: String) {
        val wasActive = nativeDetector.isNotEmpty()
        nativeDetector = name
        if (name.isEmpty()) NitraDetectors.stop(textureId)
        // Rebuild the repeating request when the frame-reader target must be
        // added/removed (detector needs frames even without frame processing).
        // Skip when the session isn't fully configured yet (captureSession or
        // currentRequestBuilder still null): the initial configuration already
        // includes the frameReader target when nativeDetector is set — see
        // sendPreviewRequest — so a rebuild here would be a redundant, racy
        // extra setRepeatingRequest during session bring-up.
        if (wasActive != name.isNotEmpty() && !frameProcessingEnabled) {
            cameraHandler.post {
                val session = captureSession ?: return@post
                if (currentRequestBuilder == null) return@post
                if (!isClosed) sendPreviewRequest(session)
            }
        }
    }
    fun lockExposure(locked: Boolean) { aeLocked = locked; triggerUpdate() }
    fun lockWhiteBalance(locked: Boolean) { awbLocked = locked; triggerUpdate() }
    fun lockFocus(locked: Boolean) { afLocked = locked; triggerUpdate() }
    /**
     * Locks the preview/output rotation to [degrees] (0/90/180/270), overriding
     * the automatic follow-the-display behaviour; -1 resumes auto. Takes effect
     * on the next rendered frame.
     */
    fun setTargetOrientation(degrees: Int) {
        targetOrientationDeg = degrees
        renderer.displayRotationDegrees =
            if (degrees >= 0) degrees else currentDisplayRotationDegrees()
    }

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



    suspend fun takePhoto(options: PhotoOptions? = null): PhotoResult {
        onEvent?.invoke(CameraEventType.PHOTOCAPTUREBEGAN, InterruptionReason.NONE, "")
        // The scene-mode HDR still request is what some HALs (e.g. Oplus at full
        // res) reject with REASON_ERROR — and a failed-then-retried capture is the
        // "slow photo". So DON'T use it on the primary request: the common path now
        // succeeds first try. A minimal request is still kept as a safety retry.
        return try {
            doCapture(useHdr = false, minimal = false, options = options)
        } catch (e: Exception) {
            Log.w("NitroCamera", "takePhoto failed (${e.message}); retrying minimal request")
            doCapture(useHdr = false, minimal = true, options = options)
        }
    }

    /**
     * Runs the standard Camera2 AE PRECAPTURE metering sequence on the live
     * repeating preview stream and waits (bounded, [PRECAPTURE_TIMEOUT_MS]) for
     * AE to settle. Without this, a still request carrying
     * AE_MODE_ON_ALWAYS_FLASH / ON_AUTO_FLASH captures its frame before the
     * flash is armed, so the flash never visibly fires on most HALs — that was
     * exactly the "flash doesn't fire on the back camera" bug (the old code set
     * TRIGGER_START on the still request itself, AFTER stopRepeating(), so the
     * sequence had no frames to run on). Never throws: on any failure or
     * timeout the still capture proceeds anyway.
     */
    private suspend fun runFlashPrecapture(session: CameraCaptureSession) {
        val pSurface = previewSurface ?: return
        if (!pSurface.isValid) return
        val settled = CompletableDeferred<Unit>()
        // Camera2Basic-style two-phase wait:
        //   1) AE enters PRECAPTURE (or immediately reports FLASH_REQUIRED),
        //   2) AE leaves PRECAPTURE → CONVERGED / FLASH_REQUIRED (flash armed).
        var precaptureSeen = false
        val callback = object : CameraCaptureSession.CaptureCallback() {
            private fun handle(result: CaptureResult) {
                val ae = result.get(CaptureResult.CONTROL_AE_STATE)
                if (ae == null) { settled.complete(Unit); return } // LEGACY HAL: no AE state
                if (!precaptureSeen) {
                    when (ae) {
                        CaptureResult.CONTROL_AE_STATE_PRECAPTURE,
                        CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED -> precaptureSeen = true
                        // Some HALs skip the PRECAPTURE state entirely.
                        CaptureResult.CONTROL_AE_STATE_CONVERGED -> settled.complete(Unit)
                    }
                }
                if (precaptureSeen && ae != CaptureResult.CONTROL_AE_STATE_PRECAPTURE) {
                    settled.complete(Unit)
                }
            }
            override fun onCaptureProgressed(
                s: CameraCaptureSession, r: CaptureRequest, partial: CaptureResult,
            ) = handle(partial)
            override fun onCaptureCompleted(
                s: CameraCaptureSession, r: CaptureRequest, result: TotalCaptureResult,
            ) = handle(result)
        }
        try {
            // Watch AE states on the repeating preview stream… (fresh builder —
            // currentRequestBuilder is owned by the camera thread). Mirror the
            // normal repeating targets so neither a scanner/detector nor an
            // active persistent-surface recording stalls meanwhile.
            val recordSurface = recordingViaSessionSurface
            val repeating = cameraDevice.createCaptureRequest(
                if (recordSurface != null) android.hardware.camera2.CameraDevice.TEMPLATE_RECORD
                else android.hardware.camera2.CameraDevice.TEMPLATE_PREVIEW)
            repeating.addTarget(pSurface)
            if (recordSurface != null) repeating.addTarget(recordSurface)
            if (frameProcessingEnabled || nativeDetector.isNotEmpty()) {
                repeating.addTarget(frameReader.surface)
            }
            applySessionSettings(repeating)
            session.setRepeatingRequest(repeating.build(), callback, cameraHandler)

            // …and kick the metering sequence with a single triggered frame.
            val trigger = cameraDevice.createCaptureRequest(
                android.hardware.camera2.CameraDevice.TEMPLATE_PREVIEW)
            trigger.addTarget(pSurface)
            applySessionSettings(trigger)
            trigger.set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER,
                CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER_START)
            session.capture(trigger.build(), callback, cameraHandler)

            val t0 = android.os.SystemClock.elapsedRealtime()
            val outcome = withTimeoutOrNull(PRECAPTURE_TIMEOUT_MS) { settled.await() }
            Log.i("NitroCamera", "Flash precapture " +
                (if (outcome != null) "settled" else "TIMED OUT (capturing anyway)") +
                " in ${android.os.SystemClock.elapsedRealtime() - t0}ms (flashMode=$flashMode)")
        } catch (e: Exception) {
            Log.w("NitroCamera", "Flash precapture failed (${e.message}); capturing anyway")
        }
    }

    /**
     * Screen-fill flash for flash-less (front) cameras: boosts the activity
     * window to max brightness so the Dart-side white overlay actually lights
     * the subject. Returns the previous screenBrightness override for
     * [restoreWindowBrightness]; null when no activity is attached.
     */
    private fun boostWindowBrightness(): Float? {
        val act = NitroCameraJniBridge.activity ?: run {
            Log.w("NitroCamera", "Screen-flash: no activity attached; skipping brightness boost")
            return null
        }
        return try {
            val previous = act.window.attributes.screenBrightness
            act.runOnUiThread {
                try {
                    val lp = act.window.attributes
                    lp.screenBrightness = 1.0f
                    act.window.attributes = lp
                } catch (e: Exception) {
                    Log.w("NitroCamera", "Screen-flash brightness boost failed: ${e.message}")
                }
            }
            Log.i("NitroCamera", "Screen-flash: window brightness boosted to 1.0 (was $previous)")
            previous
        } catch (e: Exception) {
            Log.w("NitroCamera", "Screen-flash brightness boost failed: ${e.message}")
            null
        }
    }

    /** Restores the pre-boost window brightness ([previous]; null → system default). */
    private fun restoreWindowBrightness(previous: Float?) {
        val act = NitroCameraJniBridge.activity ?: return
        act.runOnUiThread {
            try {
                val lp = act.window.attributes
                lp.screenBrightness = previous
                    ?: android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                act.window.attributes = lp
                Log.i("NitroCamera", "Screen-flash: window brightness restored to ${lp.screenBrightness}")
            } catch (_: Exception) {}
        }
    }

    private suspend fun doCapture(
        useHdr: Boolean,
        minimal: Boolean,
        options: PhotoOptions? = null,
    ): PhotoResult {
        val session = captureSession ?: throw Exception("No active session")

        val wantsFlash = !minimal && !torchEnabled && (flashMode == 1L || flashMode == 2L)

        // Flash-equipped camera (back): run the AE PRECAPTURE sequence on the
        // LIVE repeating stream BEFORE stopping it — this is what actually arms
        // the flash for the still (both flash=on and flash=auto need it).
        if (wantsFlash && hasFlashUnit) {
            runFlashPrecapture(session)
        }

        // Flash-less camera (front): "flash" = screen fill. Emit the shutter
        // event EARLY so the app's white FlashOverlay is up during exposure,
        // boost the window to max brightness, and give the display + AE a
        // moment to light the subject. Brightness restored in the finally.
        val screenFlash = wantsFlash && !hasFlashUnit
        var previousBrightness: Float? = null
        if (screenFlash) {
            Log.i("NitroCamera", "Screen-flash capture: flashMode=$flashMode (no flash unit)")
            onEvent?.invoke(CameraEventType.PHOTOCAPTURESHUTTER, InterruptionReason.NONE, "")
            previousBrightness = boostWindowBrightness()
            delay(SCREEN_FLASH_ILLUMINATION_MS)
        }

        try {
            // Stop the preview repeating request to prepare for the still capture.
            try { session.stopRepeating() } catch (_: Exception) {}

            val builder = cameraDevice.createCaptureRequest(
                android.hardware.camera2.CameraDevice.TEMPLATE_STILL_CAPTURE)
            builder.addTarget(mediaManager.photoReader.surface)

            val orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            builder.set(CaptureRequest.JPEG_ORIENTATION, orientation)

            // PhotoOptions.qualityPrioritization → JPEG compression level
            // (0 = speed, 1 = balanced, 2 = quality).
            if (options != null) {
                val quality: Byte = when (options.qualityPrioritization) {
                    0L -> 85
                    2L -> 100
                    else -> 92
                }
                builder.set(CaptureRequest.JPEG_QUALITY, quality)
            }

            if (minimal) {
                builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            } else {
                // Sets AE_MODE_ON_ALWAYS_FLASH (on) / ON_AUTO_FLASH (auto) — with
                // STILL_CAPTURE intent + the completed precapture above, the HAL
                // fires the flash for this frame. (No TRIGGER_START here: the old
                // trigger-on-the-still bug captured the frame before the flash.)
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
                // Auto red-eye reduction — only meaningful with auto-flash on a
                // flash-equipped camera advertising the REDEYE AE mode.
                if (options?.enableAutoRedEyeReduction == 1L && flashMode == 2L && hasFlashUnit) {
                    val aeModes = characteristics.get(
                        CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES) ?: intArrayOf()
                    if (aeModes.contains(CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH_REDEYE)) {
                        builder.set(CaptureRequest.CONTROL_AE_MODE,
                            CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH_REDEYE)
                        builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
                    }
                }
            }

            // The shutter moment (drives the app's shutter-flash animation).
            // The screen-flash path already emitted it before the illumination delay.
            if (!screenFlash) {
                onEvent?.invoke(CameraEventType.PHOTOCAPTURESHUTTER, InterruptionReason.NONE, "")
            }

            return mediaManager.takePhotoWithRequest(
                session = session,
                request = builder.build(),
                renderer = renderer,
                shader = lastRawShader ?: "",
                options = options,
            ) {
                // Resume the preview repeating request after capture.
                cameraHandler.post { triggerUpdate() }
            }
        } finally {
            if (screenFlash) restoreWindowBrightness(previousBrightness)
        }
    }

    /**
     * RAW (DNG) still capture — PhotoOptions.outputFormat == 1.
     *
     * RAW_SENSOR can't be piggybacked onto the normal preview/JPEG/YUV stream
     * combination on most devices, so this reconfigures a TEMPORARY capture
     * session over [preview, RAW], captures one frame together with its
     * TotalCaptureResult, writes the DNG via DngCreator, and restores the normal
     * preview session (the existing startPreview() configuration path) in a
     * finally block. Acceptable for stills; the preview freezes briefly.
     */
    suspend fun takeDngPhoto(options: PhotoOptions): PhotoResult {
        if (isClosed) throw IllegalStateException("Camera session is closed")
        if (mediaManager.isRecording) {
            throw IllegalStateException("Cannot capture DNG while recording video")
        }
        val caps = characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
            ?: intArrayOf()
        if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW)) {
            throw IllegalStateException("RAW capture not supported by this camera")
        }

        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val rawSize = map?.getOutputSizes(ImageFormat.RAW_SENSOR)
            ?.maxByOrNull { it.width.toLong() * it.height }
            ?: characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)?.let {
                android.util.Size(it.width, it.height)
            }
            ?: throw IllegalStateException("No RAW_SENSOR output size available")

        val pSurface = previewSurface
            ?: throw IllegalStateException("Preview surface not ready for RAW capture")

        val rawReader = ImageReader.newInstance(
            rawSize.width, rawSize.height, ImageFormat.RAW_SENSOR, 2)
        var rawSession: CameraCaptureSession? = null

        // Tear down the normal session — it is restored in the finally block.
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null

        try {
            rawSession = suspendCancellableCoroutine<CameraCaptureSession> { cont ->
                try {
                    cameraDevice.createCaptureSession(
                        listOf(pSurface, rawReader.surface),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                if (cont.isActive) cont.resume(session)
                            }
                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                session.close()
                                if (cont.isActive) cont.resumeWith(Result.failure(
                                    IllegalStateException("RAW capture session configuration failed")))
                            }
                        },
                        cameraHandler,
                    )
                } catch (e: Exception) {
                    if (cont.isActive) cont.resumeWith(Result.failure(e))
                }
            }

            val imageDeferred = CompletableDeferred<android.media.Image>()
            val resultDeferred = CompletableDeferred<TotalCaptureResult>()
            rawReader.setOnImageAvailableListener({ reader ->
                val img = try {
                    reader.acquireNextImage()
                } catch (e: Exception) {
                    imageDeferred.completeExceptionally(e)
                    null
                }
                if (img != null && !imageDeferred.complete(img)) img.close()
            }, cameraHandler)

            val builder = cameraDevice.createCaptureRequest(
                android.hardware.camera2.CameraDevice.TEMPLATE_STILL_CAPTURE)
            builder.addTarget(rawReader.surface)
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)

            if (options.enableShutterSound == 1L) mediaManager.playShutterSound()

            rawSession.capture(builder.build(), object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) { resultDeferred.complete(result) }

                override fun onCaptureFailed(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    val e = IllegalStateException("RAW capture failed (reason ${failure.reason})")
                    resultDeferred.completeExceptionally(e)
                    imageDeferred.completeExceptionally(e)
                }
            }, cameraHandler)

            val image = withTimeout(10_000) { imageDeferred.await() }
            val totalResult = try {
                withTimeout(10_000) { resultDeferred.await() }
            } catch (e: Exception) {
                image.close()
                throw e
            }

            val sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val isFront = characteristics.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_FRONT

            val file = withContext(Dispatchers.IO) {
                val dng = DngCreator(characteristics, totalResult)
                try {
                    dng.setOrientation(when (sensorOrientation) {
                        90 -> android.media.ExifInterface.ORIENTATION_ROTATE_90
                        180 -> android.media.ExifInterface.ORIENTATION_ROTATE_180
                        270 -> android.media.ExifInterface.ORIENTATION_ROTATE_270
                        else -> android.media.ExifInterface.ORIENTATION_NORMAL
                    })
                    if (options.hasLocation == 1L && options.skipMetadata == 0L) {
                        dng.setLocation(android.location.Location("nitro_camera").apply {
                            latitude = options.latitude
                            longitude = options.longitude
                            altitude = options.altitude
                        })
                    }
                    val out = java.io.File(context.cacheDir, "cap_${System.currentTimeMillis()}.dng")
                    java.io.FileOutputStream(out).use { dng.writeImage(it, image) }
                    out
                } finally {
                    try { dng.close() } catch (_: Exception) {}
                    try { image.close() } catch (_: Exception) {}
                }
            }

            return PhotoResult(
                path        = file.absolutePath,
                width       = rawSize.width.toLong(),
                height      = rawSize.height.toLong(),
                fileSize    = file.length(),
                orientation = sensorOrientation.toLong(),
                isMirrored  = if (isFront) 1L else 0L,
                timestamp   = System.currentTimeMillis(),
            )
        } catch (e: Exception) {
            throw IllegalStateException("DNG capture failed: ${e.message}", e)
        } finally {
            try { rawSession?.close() } catch (_: Exception) {}
            try { rawReader.close() } catch (_: Exception) {}
            // Restore the normal preview session via the existing config path.
            if (!isClosed) startPreview()
        }
    }

    suspend fun startVideoRecording(outputPath: String, options: RecordingOptions) {
        if (isClosed) throw IllegalStateException("Camera session is closed")
        // Auto-stop (maxDuration/maxFileSize) → finalise + emit a `stopped` event
        // carrying the path (no pending stopVideoRecording call in that path).
        // stopVideoRecording() routes both the persistent-surface and GL paths.
        mediaManager.onMaxReached = {
            val result = stopVideoRecording()
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
                    // FAST PATH — the persistent recorder surface is already part of
                    // the capture session: prepare the recorder on it, add it as a
                    // repeating-request target, then start. No session reconfiguration
                    // → near-instant recording start. (Frames rendered to a persistent
                    // input surface before start() are discarded by the encoder, so
                    // target-then-start is safe.)
                    val session = captureSession
                    val persistent = if (persistentSurfaceInSession && !persistentSurfaceUnusable) {
                        mediaManager.persistentRecorderSurfaceOrNull
                    } else null
                    if (session != null && persistent != null) {
                        try {
                            mediaManager.prepareVideoRecorder(
                                outputPath,
                                codec = options.codec.toInt(),
                                bitRate = options.bitRate.toInt(),
                                maxDurationMs = options.maxDurationMs.toInt(),
                                maxFileSizeBytes = options.maxFileSizeBytes,
                                lat = options.latitude,
                                lon = options.longitude,
                                hasLocation = options.hasLocation != 0L,
                                inputSurface = persistent,
                            )
                            recordingViaSessionSurface = persistent
                            sendPreviewRequest(session) // repeating request now feeds the recorder
                            mediaManager.startVideoRecorder()
                            Log.d("NitroCamera", "Video recording started on persistent session surface")
                            if (cont.isActive) cont.resume(Unit)
                            return@post
                        } catch (e: Exception) {
                            // Some devices reject persistent-surface recording at
                            // prepare/start → clean up and fall back to the GL
                            // pipeline below so recording never breaks.
                            Log.w("NitroCamera",
                                "Persistent-surface recording failed (${e.message}); falling back to GL pipeline")
                            recordingViaSessionSurface = null
                            try { mediaManager.stopVideoRecording() } catch (_: Exception) {}
                            try { sendPreviewRequest(session) } catch (_: Exception) {}
                        }
                    }

                    // FALLBACK — GL pipeline (previous behaviour): the renderer copies
                    // frames into the recorder-owned surface.
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
        if (recordingViaSessionSurface != null) {
            // Persistent-surface path: drop the recorder target from the repeating
            // request FIRST (stops feeding the encoder), then stop the recorder.
            // The session itself keeps running — no reconfiguration needed.
            recordingViaSessionSurface = null
            runOnCameraThreadBlocking {
                try {
                    captureSession?.let { if (!isClosed) sendPreviewRequest(it) }
                } catch (_: Exception) {}
            }
            return mediaManager.stopVideoRecording()
        }

        // GL pipeline path:
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

    /** Runs [block] on the camera thread; inline when already on it (avoids a
     *  deadlock when MediaRecorder callbacks — e.g. onMaxReached — fire there). */
    private fun runOnCameraThreadBlocking(block: () -> Unit) {
        if (android.os.Looper.myLooper() == cameraHandler.looper) { block(); return }
        val latch = java.util.concurrent.CountDownLatch(1)
        cameraHandler.post { try { block() } finally { latch.countDown() } }
        try { latch.await(300, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: Exception) {}
    }

    fun pauseVideoRecording()  { mediaManager.pauseVideoRecording() }
    fun resumeVideoRecording() { mediaManager.resumeVideoRecording() }
    fun cancelVideoRecording() {
        if (recordingViaSessionSurface != null) {
            // Persistent path: restores the preview repeating request; the capture
            // session stays as-is (no reconfiguration needed).
            stopVideoRecording()
            return
        }
        glHandler.post { renderer.setRecordingSurface(null) }
        mediaManager.stopVideoRecording()
        startPreview()
    }

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
