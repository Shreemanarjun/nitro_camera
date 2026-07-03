package dev.shreeman.nitro_camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import nitro.nitro_camera_module.*
import org.json.JSONArray
import org.json.JSONObject
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume

class NitroCameraImpl(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
) : HybridNitroCameraSpec, DefaultLifecycleObserver {

    // `activity` and `applicationContext` are provided by HybridNitroCameraSpec /
    // NitroCameraJniBridge (nitro >= 0.5); the plugin feeds them via
    // NitroCameraJniBridge.onActivityAttached/Detached.

    override fun onStop(owner: LifecycleOwner) {
        super.onStop(owner)
        Log.d(TAG, "App stopped, pausing all camera sessions")
        activity?.window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        sessions.values.forEach { it.onAppStop() }
    }

    override fun onResume(owner: LifecycleOwner) {
        super.onResume(owner)
        Log.d(TAG, "App resumed, resuming all camera sessions")
        activity?.window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        sessions.values.forEach { session ->
            scope.launch { session.onAppResume(cameraManager) }
        }
    }

    override fun onDestroy(owner: LifecycleOwner) {
        super.onDestroy(owner)
        Log.d(TAG, "App destroyed, resetting camera implementation")
        scope.launch { reset() }
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())


    private var permissionContinuation: CancellableContinuation<Long>? = null
    private val PERMISSION_REQUEST_CODE = 4001

    fun handlePermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            permissionContinuation?.let { 
                if (it.isActive) {
                    it.resume(if (granted) 1L else 2L) { /* onCancellation */ }
                }
            }
            permissionContinuation = null
            return true
        }
        return false
    }

    override fun reset() {
        runBlocking { closeAll() }
    }

    suspend fun closeAll() = coroutineScope {
        val activeSessions = synchronized(sessionsLock) {
            val list = sessions.values.toList()
            sessions.clear()
            list
        }
        activeSessions.map { async(Dispatchers.IO) { runCatching { it.close() } } }.awaitAll()
        // Also drain background teardowns still in flight from closeCamera().
        // Bounded: reset() runBlocking-s this on the main thread, and a close's
        // main-thread hop must not be able to deadlock app destruction.
        withTimeoutOrNull(3_000) { pendingCloses.values.toList().joinAll() }
        // Release any retired frozen-frame textures immediately (their linger
        // timers may still be pending).
        val retired = retiredTextures.values.toList()
        retiredTextures.clear()
        retired.forEach { runCatching { it.releaseTexture() } }
    }

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val sessions = ConcurrentHashMap<Long, NitraCameraSession>()
    private val sessionsLock = Any()

    private val openHandlerThread = android.os.HandlerThread("NitraOpenThread").also { it.start() }
    private val openHandler = Handler(openHandlerThread.looper)

    private val _frameFlow = MutableSharedFlow<CameraFrame>(extraBufferCapacity = 10)
    override val frameStream: SharedFlow<CameraFrame> = _frameFlow

    private val _eventFlow = MutableSharedFlow<CameraEvent>(extraBufferCapacity = 32)
    override val eventStream: SharedFlow<CameraEvent> = _eventFlow

    private fun emitEvent(
        type: CameraEventType,
        textureId: Long = 0L,
        reason: InterruptionReason = InterruptionReason.NONE,
        message: String = "",
    ) {
        _eventFlow.tryEmit(
            CameraEvent(type.nativeValue, textureId, reason.nativeValue, message)
        )
    }

    companion object {
        private const val TAG = "NitroCamera"

        /// How long openCamera waits for in-flight session teardowns before
        /// opening anyway (closes are ~100ms; the timeout only bounds
        /// pathological cases so a wedged close can't block opens forever).
        private const val PENDING_CLOSE_TIMEOUT_MS = 2_500L

        /// How long a closed session's Flutter texture stays registered so a
        /// mounted Texture widget keeps its frozen last frame while the
        /// device-switch swap completes.
        private const val RETIRED_TEXTURE_LINGER_MS = 3_000L
    }

    private var _cachedIds: List<String>? = null

    /// Public IDs + hidden numeric IDs. OEMs (OnePlus/Xiaomi…) hide extra
    /// physical lenses (macro/tele) from cameraIdList; probing 0..9 with
    /// getCameraCharacteristics finds the openable ones (stock apps show 4
    /// lenses where the public list has 3). Probe failures are ignored.
    private fun getIds(): List<String> {
        // Public IDs only. Probing hidden numeric IDs was tried and REVERTED:
        // OnePlus answers getCameraCharacteristics for hidden lenses but
        // REJECTS openCamera ("unknown device") — unopenable devices in the
        // list wedge the camera switch. Stock's 4th lens needs privileged
        // access; the 2× digital chip covers that UX instead.
        return _cachedIds ?: cameraManager.cameraIdList.toList().also { _cachedIds = it }
    }

    private val _charsCache = ConcurrentHashMap<String, CameraCharacteristics>()
    private fun getCharacteristics(id: String): CameraCharacteristics {
        return _charsCache.getOrPut(id) { cameraManager.getCameraCharacteristics(id) }
    }

    override fun getCameraPermissionStatus(): Long {
        return if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED) 1L else 2L
    }

    override suspend fun requestCameraPermission(): Long {
        if (getCameraPermissionStatus() == 1L) return 1L
        val act = activity ?: return 0L
        return suspendCancellableCoroutine { cont ->
            permissionContinuation = cont
            cont.invokeOnCancellation { permissionContinuation = null }
            androidx.core.app.ActivityCompat.requestPermissions(
                act,
                arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    override fun getMicrophonePermissionStatus(): Long {
        return if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED) 1L else 2L
    }
    
    override suspend fun requestMicrophonePermission(): Long {
        return requestCameraPermission()
    }

    override fun getDeviceCount(): Long = getIds().size.toLong()

    override suspend fun getAvailableCameraDevicesJson(): String {
        val arr = JSONArray()
        for (id in getIds()) {
            arr.put(buildCameraDeviceJson(id, getCharacteristics(id)))
        }
        return arr.toString()
    }

    override fun getAvailableCameraDevices(): List<CameraDevice> {
        return getIds().map { id -> buildCameraDevice(id, getCharacteristics(id)) }
    }

    override fun getDevice(index: Long): CameraDevice {
        val ids = getIds()
        if (index < 0 || index >= ids.size) throw Exception("Camera index out of bounds")
        val id = ids[index.toInt()]
        return buildCameraDevice(id, getCharacteristics(id))
    }

    /// ONE serial queue for ALL camera hardware transitions (vision-camera's
    /// classic CameraQueues.cameraQueue model): every open and close runs
    /// through this mutex, so two opens can never overlap and an open can
    /// never race a close. The close INTERNALS stay parallelized (~100ms, see
    /// NitraCameraSession.closeKeepTexture) — only the ordering is serial.
    ///
    /// Background: guarding only cameraManager.openCamera (and letting closes
    /// run detached) let a new open overlap the previous session's teardown.
    /// Constrained HALs (OnePlus/oplus) wedge in that state and storm
    /// "getCameraCharacteristics: unable to retrieve camera characteristics
    /// for unknown device N: No such file or directory (-2)" for EVERY id
    /// until the camera service recovers.
    private val cameraQueue = Mutex()

    // deviceId -> in-flight teardown of that device's old session. closeCamera
    // awaits these before returning, but reset()/un-awaited disposals can still
    // leave jobs in flight — openCamera joins ALL of them before opening.
    private val pendingCloses = ConcurrentHashMap<String, Job>()

    // Closed sessions whose Flutter texture is still registered so a mounted
    // Texture widget keeps its frozen last frame during a device switch. The
    // texture is released RETIRED_TEXTURE_LINGER_MS after the hardware close
    // (or immediately on closeAll).
    private val retiredTextures = ConcurrentHashMap<Long, NitraCameraSession>()

    // Duration of the most recent session close (for the switch timing log).
    @Volatile private var lastCloseDurationMs: Long = 0L

    private suspend fun awaitPendingCloses(reason: String) {
        val pending = pendingCloses.values.toList()
        if (pending.isEmpty()) return
        val done = withTimeoutOrNull(PENDING_CLOSE_TIMEOUT_MS) { pending.joinAll() }
        if (done == null) {
            Log.w(TAG, "$reason: pending closes did not finish within " +
                "${PENDING_CLOSE_TIMEOUT_MS}ms; proceeding anyway")
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override suspend fun openCamera(
        deviceId: String, width: Long, height: Long, fps: Long, enableAudio: Long,
    ): Long {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) throw SecurityException("Camera permission not granted")

        val openStart = android.os.SystemClock.elapsedRealtime()

        var textureId: Long = 0
        var surfaceProducer: Any? = null
        var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val producer = withContext(Dispatchers.Main) { textureRegistry.createSurfaceProducer() }
                surfaceProducer = producer
                textureId = producer.id()
            } catch (e: Exception) {
                val entry = withContext(Dispatchers.Main) { textureRegistry.createSurfaceTexture() }
                surfaceTextureEntry = entry
                textureId = entry.id()
            }
        } else {
            val entry = withContext(Dispatchers.Main) { textureRegistry.createSurfaceTexture() }
            surfaceTextureEntry = entry
            textureId = entry.id()
        }

        val availableIds = getIds()
        if (!availableIds.contains(deviceId)) {
            Log.e(TAG, "Unknown camera device $deviceId.")
            withContext(Dispatchers.Main) {
               surfaceTextureEntry?.release()
               (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)?.release()
            }
            return 0L
        }

        try {
            val awaitOpen: suspend () -> android.hardware.camera2.CameraDevice = {
                suspendCancellableCoroutine { cont ->
                    cont.invokeOnCancellation {
                        Handler(Looper.getMainLooper()).post {
                           surfaceTextureEntry?.release()
                           (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)?.release()
                        }
                    }

                    try {
                        cameraManager.openCamera(
                            deviceId,
                            object : android.hardware.camera2.CameraDevice.StateCallback() {
                                override fun onOpened(cam: android.hardware.camera2.CameraDevice) {
                                    if (cont.isActive) cont.resume(cam) { cam.close() } else cam.close()
                                }
                                override fun onDisconnected(cam: android.hardware.camera2.CameraDevice) {
                                    cam.close()
                                    if (cont.isActive) cont.cancel()
                                }
                                override fun onError(cam: android.hardware.camera2.CameraDevice, error: Int) {
                                    cam.close()
                                    if (cont.isActive) cont.resumeWith(Result.failure(Exception("Camera open error $error")))
                                }
                            },
                            openHandler,
                        )
                    } catch (e: Exception) {
                        if (cont.isActive) cont.resumeWith(Result.failure(e))
                    }
                }
            }

            // The ENTIRE open sequence runs on the serial camera queue
            // (vision-camera's model): two opens can never overlap, and no
            // open can start while any close is still in flight. Closes are
            // fast (~100ms, parallelized internals), so serial close→open
            // stays quick; the CameraView freeze-frame swap keeps the old
            // frame on screen meanwhile.
            return cameraQueue.withLock {
                awaitPendingCloses("openCamera($deviceId)")

                val camera = try {
                    awaitOpen()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Constrained HALs can reject an open right after another
                    // device's close (or while the service is settling) —
                    // drain any remaining teardowns, give the HAL a moment,
                    // and retry once. Deeper failures surface to Dart, which
                    // retries with exponential backoff.
                    Log.w(TAG, "openCamera($deviceId) failed (${e.message}); " +
                        "retrying once after the HAL settles")
                    runCatching { pendingCloses.values.toList().joinAll() }
                    delay(200)
                    awaitOpen()
                }

                val session = NitraCameraSession(
                    context      = context,
                    textureId    = textureId,
                    surfaceEntry = surfaceTextureEntry,
                    surfaceProducer = surfaceProducer,
                    cameraDevice = camera,
                    characteristics = getCharacteristics(deviceId),
                    deviceId     = deviceId,
                    width        = width.toInt(),
                    height       = height.toInt(),
                    requestedFps = fps.toInt(),
                    enableAudio  = enableAudio != 0L,
                )
                session.onFrame = { frame -> _frameFlow.tryEmit(frame) }
                session.onEvent = { type, reason, message ->
                    _eventFlow.tryEmit(CameraEvent(type.nativeValue, textureId, reason.nativeValue, message))
                }
                synchronized(sessionsLock) { sessions[textureId] = session }

                session.startPreview()
                val openMs = android.os.SystemClock.elapsedRealtime() - openStart
                Log.i(TAG, "switch: close=${lastCloseDurationMs}ms open=${openMs}ms")
                textureId
            }
        } catch (e: Exception) {
            Log.e(TAG, "General openCamera failure: ${e.message}")
            // Scope the failure to THIS texture id — a 0L broadcast id would
            // surface the error on every other live session's event stream.
            emitEvent(CameraEventType.ERROR, textureId = textureId,
                message = "openCamera failed: ${e.message}")
            withContext(Dispatchers.Main) {
                surfaceTextureEntry?.release()
                (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)?.release()
            }
            return 0L
        }
    }

    fun attachPlatformView(textureId: Long, surface: Surface) {
        session(textureId)?.attachPlatformSurface(surface)
    }

    fun detachPlatformView(textureId: Long) {
        session(textureId)?.detachPlatformSurface()
    }

    override suspend fun closeCamera(textureId: Long) {
        val s = synchronized(sessionsLock) { sessions.remove(textureId) } ?: return
        val devId = s.deviceId
        val closeStart = android.os.SystemClock.elapsedRealtime()
        // Serialized with every open/close on the camera queue. The hardware
        // teardown itself is parallelized inside closeKeepTexture (~100ms);
        // the FLUTTER TEXTURE stays registered so a mounted Texture widget
        // keeps its frozen last frame during a device switch — it is released
        // after RETIRED_TEXTURE_LINGER_MS (below) or on closeAll().
        cameraQueue.withLock {
            val job = scope.launch(Dispatchers.IO) {
                try {
                    s.closeKeepTexture()
                } catch (e: Exception) {
                    Log.w(TAG, "closeCamera($textureId) failed: ${e.message}")
                }
                lastCloseDurationMs = android.os.SystemClock.elapsedRealtime() - closeStart
                Log.i(TAG, "switch: close=${lastCloseDurationMs}ms (device $devId)")
            }
            pendingCloses[devId] = job
            job.invokeOnCompletion { pendingCloses.remove(devId, job) }
            retiredTextures[textureId] = s
            // Await the hardware teardown so callers get a deterministic
            // close-before-open ordering (openCamera additionally joins
            // pendingCloses as a safety net for un-awaited disposals).
            job.join()
        }
        // Deferred texture release, OFF the camera queue: gives the Dart-side
        // swap time to unmount the frozen old preview first.
        scope.launch {
            delay(RETIRED_TEXTURE_LINGER_MS)
            retiredTextures.remove(textureId)?.let { retired ->
                runCatching { retired.releaseTexture() }
            }
        }
    }

    override fun startPreview(textureId: Long) { session(textureId)?.startPreview() }
    override fun stopPreview(textureId: Long)  { session(textureId)?.stopPreview() }

    override fun setZoom(textureId: Long, zoom: Double)                { session(textureId)?.setZoom(zoom) }
    override fun setFocusPoint(textureId: Long, x: Double, y: Double)  { session(textureId)?.setFocusPoint(x, y) }
    override fun setAutoFocus(textureId: Long, mode: Long)              { session(textureId)?.setAutoFocus(mode) }
    override fun setExposure(textureId: Long, value: Double)            { session(textureId)?.setExposure(value) }
    override fun setFlash(textureId: Long, mode: Long)                  { session(textureId)?.setFlash(mode) }
    override fun setTorch(textureId: Long, enabled: Long)               { session(textureId)?.setTorch(enabled != 0L) }
    override fun setWhiteBalance(textureId: Long, temperature: Long)    { session(textureId)?.setWhiteBalance(temperature) }
    override fun setHdr(textureId: Long, enabled: Long)                 { session(textureId)?.setHdr(enabled != 0L) }

    override suspend fun takePhoto(textureId: Long): PhotoResult =
        session(textureId)?.takePhoto() ?: error("No session")

    override suspend fun startVideoRecording(textureId: Long, outputPath: String, options: RecordingOptions) {
        session(textureId)?.startVideoRecording(outputPath, options)
    }

    override suspend fun stopVideoRecording(textureId: Long): RecordingResult =
        session(textureId)?.stopVideoRecording() ?: RecordingResult("", 0L, 0L)

    override fun pauseRecording(textureId: Long)  { session(textureId)?.pauseVideoRecording() }
    override fun resumeRecording(textureId: Long) { session(textureId)?.resumeVideoRecording() }
    override fun cancelRecording(textureId: Long) { session(textureId)?.cancelVideoRecording() }

    override fun enableFrameProcessing(textureId: Long, enabled: Long) {
        session(textureId)?.frameProcessingEnabled = (enabled != 0L)
    }

    override fun setFrameFormat(textureId: Long, format: Long)            { session(textureId)?.setFrameFormat(format) }
    override fun setSamplingRate(textureId: Long, samplingRate: Long)      { session(textureId)?.setSamplingRate(samplingRate) }
    override fun setFilterShader(textureId: Long, shaderSource: String)   { session(textureId)?.setFilterShader(shaderSource) }
    override fun updateOverlay(textureId: Long, overlayData: java.nio.ByteBuffer)      { /* reserved */ }

    // ---- Declarative configuration & advanced controls ----

    override suspend fun configure(textureId: Long, config: CameraConfig): ResolvedConfig {
        val s = session(textureId) ?: error("No session $textureId")
        s.setZoom(config.zoom)
        s.setExposure(config.exposure)
        s.setFlash(config.flash)
        if (config.torchLevel > 0.0) s.setTorchLevel(config.torchLevel) else s.setTorch(config.torch != 0L)
        s.setWhiteBalance(config.whiteBalanceKelvin)
        s.setHdr(config.videoHdr != 0L)
        s.setLowLightBoost(config.lowLightBoost != 0L)
        s.setAutoFocus(config.autoFocus)
        s.setVideoStabilization(config.videoStabilization)
        s.setFrameFormat(config.pixelFormat)
        s.setSamplingRate(config.samplingRate)
        s.frameProcessingEnabled = (config.enableFrameProcessing != 0L)
        if (config.active != 0L) s.startPreview() else s.stopPreview()
        val afSystem = if (config.autoFocus == 0L) 0L else 2L // off vs phase-detection
        return ResolvedConfig(
            width = s.streamWidth.toLong(),
            height = s.streamHeight.toLong(),
            fps = s.activeFps.toLong(),
            pixelFormat = s.currentPixelFormat,
            videoHdrEnabled = config.videoHdr,
            autoFocusSystem = afSystem,
            active = config.active,
        )
    }

    override fun getSessionStateJson(textureId: Long): String {
        val s = session(textureId) ?: return JSONObject().put("running", false).toString()
        return JSONObject().apply {
            put("running", s.isPreviewRunning)
            put("width", s.streamWidth)
            put("height", s.streamHeight)
            put("fps", s.activeFps)
            put("pixelFormat", s.currentPixelFormat)
        }.toString()
    }

    override fun setVideoStabilization(textureId: Long, mode: Long) { session(textureId)?.setVideoStabilization(mode) }
    override fun setLowLightBoost(textureId: Long, enabled: Long)   { session(textureId)?.setLowLightBoost(enabled != 0L) }
    override fun setDistortionCorrection(textureId: Long, enabled: Long) {
        session(textureId)?.setDistortionCorrection(enabled != 0L)
    }

    override fun setNativeDetector(textureId: Long, detector: String) {
        session(textureId)?.setNativeDetector(detector)
    }

    // ── Physical-orientation events (vision-camera's DeviceOrientationManager) ──
    //
    // OrientationEventListener reports the SENSOR-measured device rotation even
    // when the UI orientation is locked — bucketed to 0/90/180/270 and emitted
    // only on change.
    private var orientationListener: android.view.OrientationEventListener? = null
    private var lastOrientationBucket = -1

    override fun enableOrientationEvents(enabled: Long) {
        if (enabled != 0L) {
            if (orientationListener != null) return
            val listener = object : android.view.OrientationEventListener(context) {
                override fun onOrientationChanged(degrees: Int) {
                    if (degrees == ORIENTATION_UNKNOWN) return
                    // Bucket to the nearest quadrant (vision-camera's
                    // CameraOrientation.fromDegrees).
                    val bucket = when {
                        degrees >= 315 || degrees < 45 -> 0
                        degrees < 135 -> 90
                        degrees < 225 -> 180
                        else -> 270
                    }
                    if (bucket == lastOrientationBucket) return
                    lastOrientationBucket = bucket
                    _eventFlow.tryEmit(
                        CameraEvent(
                            CameraEventType.ORIENTATIONCHANGED.nativeValue,
                            0L,
                            bucket.toLong(),
                            "",
                        )
                    )
                }
            }
            orientationListener = listener
            if (listener.canDetectOrientation()) listener.enable() else orientationListener = null
        } else {
            orientationListener?.disable()
            orientationListener = null
            lastOrientationBucket = -1
        }
    }

    // ── Device hot-plug (CameraManager.AvailabilityCallback) ────────────────────
    private var availabilityCallback: CameraManager.AvailabilityCallback? = null

    override fun enableDeviceAvailabilityEvents(enabled: Long) {
        if (enabled != 0L) {
            if (availabilityCallback != null) return
            val cb = object : CameraManager.AvailabilityCallback() {
                override fun onCameraAvailable(cameraId: String) {
                    _cachedIds = null // a USB camera may have appeared
                    emitEvent(CameraEventType.DEVICECONNECTED, message = cameraId)
                }

                override fun onCameraUnavailable(cameraId: String) {
                    _cachedIds = null
                    emitEvent(CameraEventType.DEVICEDISCONNECTED, message = cameraId)
                }
            }
            availabilityCallback = cb
            cameraManager.registerAvailabilityCallback(cb, openHandler)
        } else {
            availabilityCallback?.let { cameraManager.unregisterAvailabilityCallback(it) }
            availabilityCallback = null
        }
    }

    /// Concurrent-streaming camera combinations (multi-cam), API 30+.
    override fun getConcurrentCameraIdsJson(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "[]"
        return try {
            val combos = JSONArray()
            for (set in cameraManager.concurrentCameraIds) {
                val arr = JSONArray()
                for (id in set) arr.put(id)
                combos.put(arr)
            }
            combos.toString()
        } catch (e: Exception) {
            Log.w(TAG, "concurrentCameraIds failed: ${e.message}")
            "[]"
        }
    }
    override fun setTorchLevel(textureId: Long, level: Double)      { session(textureId)?.setTorchLevel(level) }
    override fun lockExposure(textureId: Long, locked: Long)        { session(textureId)?.lockExposure(locked != 0L) }
    override fun lockFocus(textureId: Long, locked: Long)           { session(textureId)?.lockFocus(locked != 0L) }
    override fun lockWhiteBalance(textureId: Long, locked: Long)    { session(textureId)?.lockWhiteBalance(locked != 0L) }
    override fun setTargetOrientation(textureId: Long, degrees: Long) { session(textureId)?.setTargetOrientation(degrees.toInt()) }

    override suspend fun takePhotoWithOptions(textureId: Long, options: PhotoOptions): PhotoResult {
        val s = session(textureId) ?: error("No session")
        // outputFormat 1 = DNG (RAW) — dedicated capture path with its own
        // temporary RAW session; everything else is the JPEG path with the full
        // PhotoOptions honored (quality, red-eye, shutter sound, GPS EXIF, ...).
        if (options.outputFormat == 1L) return s.takeDngPhoto(options)
        s.setFlash(options.flash)
        return s.takePhoto(options)
    }

    override suspend fun takeSnapshot(textureId: Long): PhotoResult =
        session(textureId)?.takePhoto() ?: error("No session")

    private fun session(textureId: Long) = synchronized(sessionsLock) { sessions[textureId] }

    private fun buildCameraDeviceJson(cameraId: String, chars: CameraCharacteristics): JSONObject {
        val position = when (chars.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_FRONT -> 0
            CameraCharacteristics.LENS_FACING_BACK  -> 1
            else                                     -> 2
        }
        val orientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val hasFlash    = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

        // Zoom: prefer the modern ratio range (API 30, covers <1.0 ultra-wide
        // zoom-out on logical cameras) over the legacy digital-zoom max.
        var minZoom = 1.0
        var maxZoom = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.let {
                minZoom = it.lower.toDouble()
                maxZoom = it.upper.toDouble()
            }
        }

        val map      = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val jpegSizes = map?.getOutputSizes(android.graphics.ImageFormat.JPEG)?.sortedByDescending { it.width * it.height }
        val maxPhotoW = jpegSizes?.firstOrNull()?.width ?: 1920
        val maxPhotoH = jpegSizes?.firstOrNull()?.height ?: 1080

        val focalArray = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val focalLength = focalArray?.firstOrNull() ?: 3.5f
        val apertures  = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)
        val aperture   = apertures?.firstOrNull() ?: 1.8f

        val lensType = when {
            focalLength < 2.3f -> 2  // ultra-wide
            focalLength > 6.0f -> 3  // telephoto
            else               -> 1  // wide-angle
        }

        val lensName = when (lensType) { 2 -> "Ultra Wide" 3 -> "Telephoto" else -> "Wide" }
        val name     = if (position == 0) "Front Camera" else "$lensName Camera"

        val evRange  = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val evStep   = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toDouble() ?: 1.0
        val minEv    = if (evRange != null && evStep != 0.0) evRange.lower * evStep else -4.0
        val maxEv    = if (evRange != null && evStep != 0.0) evRange.upper * evStep else  4.0

        // Capabilities → RAW / depth / logical multi-cam flags.
        val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: intArrayOf()
        val supportsRaw = caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW)
        val supportsDepth = caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT)
        val isMultiCam = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)

        val hardwareLevel = when (chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY  -> "legacy"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
            else                                                         -> "full"
        }

        // Physical lens composition (vision-camera's physicalDevices). A plain
        // camera reports its own lens type; a logical camera lists its members'.
        val physical = JSONArray()
        fun lensTypeName(focal: Float) = when {
            focal < 2.3f -> "ultra-wide-angle-camera"
            focal > 6.0f -> "telephoto-camera"
            else         -> "wide-angle-camera"
        }
        if (isMultiCam && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            for (physId in chars.physicalCameraIds) {
                val pf = try {
                    getCharacteristics(physId)
                        .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.firstOrNull()
                } catch (_: Exception) { null }
                physical.put(lensTypeName(pf ?: focalLength))
            }
        } else {
            physical.put(lensTypeName(focalLength))
        }

        // Focus: LENS_INFO_MINIMUM_FOCUS_DISTANCE is in diopters; 0 = fixed-focus.
        val minFocusDiopters = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
        val minFocusDistanceCm = if (minFocusDiopters > 0f) (100.0 / minFocusDiopters) else 0.0
        val afModes = chars.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: intArrayOf()
        val supportsFocus = afModes.any { it != CameraCharacteristics.CONTROL_AF_MODE_OFF }

        // ISO + field of view (from the physical sensor size).
        val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val fieldOfView = if (sensorSize != null && focalLength > 0f) {
            Math.toDegrees(2.0 * Math.atan2(sensorSize.width / 2.0, focalLength.toDouble()))
        } else 69.4

        // Stabilization modes (digital EIS + optical OIS).
        val stabModes = JSONArray().apply { put("off") }
        val eis = chars.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES) ?: intArrayOf()
        if (eis.contains(CameraCharacteristics.CONTROL_VIDEO_STABILIZATION_MODE_ON)) stabModes.put("standard")
        val ois = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION) ?: intArrayOf()
        if (ois.contains(CameraCharacteristics.LENS_OPTICAL_STABILIZATION_MODE_ON)) stabModes.put("cinematic")

        // Vendor extensions (Night / HDR / Bokeh...), API 31+ — query-only.
        val extensions = JSONArray()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val extChars = cameraManager.getCameraExtensionCharacteristics(cameraId)
                for (ext in extChars.supportedExtensions) {
                    extensions.put(
                        when (ext) {
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_AUTOMATIC -> "auto"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_FACE_RETOUCH -> "face-retouch"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_BOKEH -> "bokeh"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_HDR -> "hdr"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_NIGHT -> "night"
                            else -> "unknown-$ext"
                        }
                    )
                }
            } catch (_: Exception) { /* extensions unsupported on this device */ }
        }

        // Real fps ranges from the AE target ranges (was hardcoded 15–30).
        val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        val deviceMinFps = fpsRanges?.minOfOrNull { it.lower }?.toDouble() ?: 15.0
        val deviceMaxFps = fpsRanges?.maxOfOrNull { it.upper }?.toDouble() ?: 30.0

        // 10-bit HDR video profiles (API 33+).
        val supportsVideoHdr = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DYNAMIC_RANGE_TEN_BIT)
        val supportsPhotoHdr = (0 until extensions.length()).any { extensions.getString(it) == "hdr" }

        val autoFocusSystem = if (supportsFocus) "contrast-detection" else "none"

        val formatsArr = JSONArray()
        val videoSizes = map?.getOutputSizes(android.graphics.ImageFormat.YUV_420_888)
            ?.sortedByDescending { it.width * it.height } ?: emptyList()

        for (size in videoSizes) {
            // High-speed ranges only apply to specific sizes; report the
            // device-wide AE range, capped to 60 fps for oversized streams
            // (large YUV streams can't sustain high-speed rates).
            val area = size.width.toLong() * size.height
            val maxFpsForSize = if (area > 1920L * 1080 && deviceMaxFps > 30.0) 30.0 else deviceMaxFps
            val fmt = JSONObject()
            fmt.put("photoWidth",  maxPhotoW)
            fmt.put("photoHeight", maxPhotoH)
            fmt.put("videoWidth",  size.width)
            fmt.put("videoHeight", size.height)
            fmt.put("minFps",      deviceMinFps)
            fmt.put("maxFps",      maxFpsForSize)
            if (isoRange != null) {
                fmt.put("minISO", isoRange.lower.toDouble())
                fmt.put("maxISO", isoRange.upper.toDouble())
            }
            fmt.put("fieldOfView", fieldOfView)
            fmt.put("supportsVideoHdr", supportsVideoHdr)
            fmt.put("supportsPhotoHdr", supportsPhotoHdr)
            fmt.put("supportsDepthCapture", supportsDepth)
            fmt.put("autoFocusSystem", autoFocusSystem)
            fmt.put("videoStabilizationModes", stabModes)
            formatsArr.put(fmt)
        }

        return JSONObject().apply {
            put("id",                  cameraId)
            put("name",                name)
            put("position",            position)
            put("lensType",            lensType)
            put("sensorOrientation",   orientation)
            put("minZoom",             minZoom)
            put("maxZoom",             maxZoom)
            put("neutralZoom",         1.0)
            put("hasFlash",            hasFlash)
            put("hasTorch",            hasFlash) // Android: torch iff flash unit
            put("maxPhotoWidth",       maxPhotoW)
            put("maxPhotoHeight",      maxPhotoH)
            put("minExposure",         minEv)
            put("maxExposure",         maxEv)
            put("minFocusDistanceCm",  minFocusDistanceCm)
            put("isMultiCam",          isMultiCam)
            put("supportsRawCapture",  supportsRaw)
            put("supportsFocus",       supportsFocus)
            put("hardwareLevel",       hardwareLevel)
            put("physicalDevices",     physical)
            put("extensions",          extensions)
            put("focalLength",         focalLength.toDouble())
            put("aperture",            aperture.toDouble())
            put("formats",             formatsArr)
        }
    }

    private fun buildCameraDevice(cameraId: String, chars: CameraCharacteristics): CameraDevice {
        val position = when (chars.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_FRONT -> 0L
            CameraCharacteristics.LENS_FACING_BACK  -> 1L
            else                                     -> 2L
        }
        val orientation = (chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0).toLong()
        val map   = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(android.graphics.ImageFormat.JPEG)?.sortedByDescending { it.width }
        val maxZoom = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        val hasFlash = if (chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true) 1L else 0L

        val focalArray = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val focalLength = focalArray?.firstOrNull() ?: 3.5f
        val apertures  = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)
        val aperture   = apertures?.firstOrNull() ?: 1.8f

        val lensType = when {
            focalLength < 2.3f -> 2L // ultra-wide
            focalLength > 6.0f -> 3L // telephoto
            else               -> 1L // wide-angle
        }

        return CameraDevice(
            id                = cameraId,
            name              = if (position == 0L) "Front Camera" else "Lens $focalLength",
            position          = position,
            lensType          = lensType,
            sensorOrientation = orientation,
            minZoom           = 1.0,
            maxZoom           = maxZoom,
            neutralZoom       = 1.0,
            hasFlash          = hasFlash,
            hasTorch          = hasFlash,
            maxPhotoWidth     = sizes?.firstOrNull()?.width?.toLong() ?: 1280L,
            maxPhotoHeight    = sizes?.firstOrNull()?.height?.toLong() ?: 720L,
            focalLength       = focalLength.toDouble(),
            aperture          = aperture.toDouble()
        )
    }
}
