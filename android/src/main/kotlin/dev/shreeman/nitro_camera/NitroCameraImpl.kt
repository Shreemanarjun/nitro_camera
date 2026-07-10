package dev.shreeman.nitro_camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.core.content.ContextCompat
import dev.shreeman.nitro_camera.core.CameraDeviceDetails
import dev.shreeman.nitro_camera.extensions.cameraErrorMessage
import dev.shreeman.nitro_camera.session.CameraSession
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

/**
 * The generated-spec facade: permissions, the device list, the SERIAL camera
 * queue (open/close ordering), hot-plug + physical-orientation observers, and
 * per-texture delegation into [CameraSession]. This class's package/name are
 * part of the plugin ABI (registered with the Nitro bridge) and must not move.
 *
 * vision-camera analogue: android/.../hybrids/HybridCameraSession.kt (their
 * generated-spec facade over session/ActiveCameraSession*).
 */
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
    private val sessions = ConcurrentHashMap<Long, CameraSession>()
    private val sessionsLock = Any()

    /// Device JSON / characteristics reading (vision-camera's HybridCameraDevice).
    private val deviceDetails = CameraDeviceDetails(cameraManager, ::getCharacteristics)

    private val openHandlerThread = android.os.HandlerThread("NitraOpenThread").also { it.start() }
    private val openHandler = Handler(openHandlerThread.looper)

    private val _frameFlow = MutableSharedFlow<CameraFrame>(extraBufferCapacity = 10)
    override val frameStream: SharedFlow<CameraFrame> = _frameFlow

    // Rate-limited frame-delivery diagnostics: one log line per ~120 frames
    // (and per 30 drops) so the emit path is observable in logcat without
    // per-frame log spam.
    private var _emitOk = 0L
    private var _emitDropped = 0L
    private fun frameEmitStats(textureId: Long, delivered: Boolean) {
        if (delivered) _emitOk++ else _emitDropped++
        if (!delivered && _emitDropped % 30 == 1L) {
            // Rate-limited frameDropped event (vision-camera onFrameDropped
            // parity; iOS emits from captureOutput didDrop). "outOfBuffers" is
            // the closest Android analogue — the Dart consumer isn't keeping up
            // with the drop-latest broadcast, so buffers are discarded.
            emitEvent(CameraEventType.FRAMEDROPPED, textureId = textureId,
                message = "outOfBuffers")
        }
        if ((delivered && _emitOk % 120 == 1L) || (!delivered && _emitDropped % 30 == 1L)) {
            Log.d(TAG, "frameEmit[$textureId]: ok=$_emitOk dropped=$_emitDropped " +
                "subscribers=${_frameFlow.subscriptionCount.value}")
        }
    }

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

    // Device-list JSON cache: characteristics, formats and vendor extensions
    // are immutable per camera, but building the JSON is expensive — the
    // extension query (getCameraExtensionCharacteristics, API 31+) alone costs
    // ~100ms of binder round-trips per camera. Built once (per-camera queries
    // in parallel), served from cache afterwards; invalidated on hot-plug
    // together with _cachedIds (see enableDeviceAvailabilityEvents).
    @Volatile private var _devicesJsonCache: String? = null

    override suspend fun getAvailableCameraDevicesJson(): String {
        _devicesJsonCache?.let { return it }
        val parts = coroutineScope {
            getIds().map { id ->
                async(Dispatchers.IO) { deviceDetails.buildCameraDeviceJson(id, getCharacteristics(id)) }
            }.awaitAll()
        }
        val json = JSONArray().also { arr -> parts.forEach { arr.put(it) } }.toString()
        _devicesJsonCache = json
        return json
    }

    override fun getAvailableCameraDevices(): List<CameraDevice> {
        return getIds().map { id -> deviceDetails.buildCameraDevice(id, getCharacteristics(id)) }
    }

    override fun getDevice(index: Long): CameraDevice {
        val ids = getIds()
        if (index < 0 || index >= ids.size) throw Exception("Camera index out of bounds")
        val id = ids[index.toInt()]
        return deviceDetails.buildCameraDevice(id, getCharacteristics(id))
    }

    /// ONE serial queue for ALL camera hardware transitions (vision-camera's
    /// classic CameraQueues.cameraQueue model): every open and close runs
    /// through this mutex, so two opens can never overlap and an open can
    /// never race a close. The close INTERNALS stay parallelized (~100ms, see
    /// CameraSession.closeKeepTexture) — only the ordering is serial.
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
    private val retiredTextures = ConcurrentHashMap<Long, CameraSession>()

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
    // Device thermal monitoring (PowerManager, API 29+). Registered lazily on
    // the first camera open and left running for the process lifetime — thermal
    // pressure is device-wide (not per-session) and cheap to observe. Emits a
    // THERMALSTATECHANGED event with the level normalized to 0..3 in `reason`
    // (nominal/fair/serious/critical), so apps can shed load before a HAL
    // throttle. vision-camera has no thermal handling — this is a net addition.
    private var _thermalListener: android.os.PowerManager.OnThermalStatusChangedListener? = null
    private fun normalizeThermal(status: Int): Long = when (status) {
        android.os.PowerManager.THERMAL_STATUS_NONE -> 0L
        android.os.PowerManager.THERMAL_STATUS_LIGHT,
        android.os.PowerManager.THERMAL_STATUS_MODERATE -> 1L
        android.os.PowerManager.THERMAL_STATUS_SEVERE,
        android.os.PowerManager.THERMAL_STATUS_CRITICAL -> 2L
        else -> 3L
    }

    private fun emitThermal(level: Long) {
        // Raw normalized level directly in `reason` (same pattern as
        // orientationChanged emitting degrees) — not an InterruptionReason.
        _eventFlow.tryEmit(
            CameraEvent(CameraEventType.THERMALSTATECHANGED.nativeValue, 0L, level, "")
        )
    }

    private fun ensureThermalMonitoring() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val pm = context.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            ?: return
        if (_thermalListener == null) {
            val listener = android.os.PowerManager.OnThermalStatusChangedListener { status ->
                emitThermal(normalizeThermal(status))
            }
            try {
                pm.addThermalStatusListener(listener)
                _thermalListener = listener
            } catch (e: Exception) {
                Log.w(TAG, "thermal monitoring unavailable: ${e.message}")
                return
            }
        }
        // addThermalStatusListener only fires on CHANGE — publish the current
        // status on every open so a consumer (or a reopen) always sees a value.
        emitThermal(normalizeThermal(pm.currentThermalStatus))
    }

    override suspend fun openCamera(
        deviceId: String, width: Long, height: Long, fps: Long, enableAudio: Long,
    ): Long {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) throw SecurityException("Camera permission not granted")
        ensureThermalMonitoring()

        val openStart = android.os.SystemClock.elapsedRealtime()

        var textureId: Long = 0
        var surfaceProducer: Any? = null
        var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null

        // Flutter texture ids are handed out from 0, but the openCamera ABI keeps
        // 0 as its "open failed" sentinel (both the Dart controller and the iOS
        // bridge use it). On a cold boot the FIRST registered texture would get
        // id 0 — a perfectly working native session that Dart then misreads as a
        // failure, leaking the session and forcing a retry (the "first open at
        // boot always fails once" bug). Burn the ambiguous id-0 registration once
        // (ids are monotonic and never reused) so real sessions start at 1.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val producer = withContext(Dispatchers.Main) {
                    var p = textureRegistry.createSurfaceProducer()
                    if (p.id() == 0L) {
                        val zero = p
                        p = textureRegistry.createSurfaceProducer()
                        runCatching { zero.release() }
                    }
                    p
                }
                surfaceProducer = producer
                textureId = producer.id()
            } catch (e: Exception) {
                val entry = withContext(Dispatchers.Main) { createNonZeroSurfaceTexture() }
                surfaceTextureEntry = entry
                textureId = entry.id()
            }
        } else {
            val entry = withContext(Dispatchers.Main) { createNonZeroSurfaceTexture() }
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
                                    if (cont.isActive) {
                                        cam.close()
                                        cont.cancel()
                                    } else {
                                        // MID-SESSION disconnect (another client
                                        // took the camera / service died). This
                                        // callback outlives the open — route it
                                        // to the live session so the interruption
                                        // surfaces as an event instead of a
                                        // silent black preview (vision-camera's
                                        // CameraState observer semantics).
                                        sessions[textureId]?.onDeviceDisconnected()
                                            ?: cam.close()
                                    }
                                }
                                override fun onError(cam: android.hardware.camera2.CameraDevice, error: Int) {
                                    if (cont.isActive) {
                                        cam.close()
                                        cont.resumeWith(Result.failure(
                                            Exception("Camera open failed: ${cameraErrorMessage(error)}")))
                                    } else {
                                        // Mid-session fatal device/service error.
                                        sessions[textureId]?.onDeviceError(error)
                                            ?: cam.close()
                                    }
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

                val session = CameraSession(
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
                session.onFrame = { frame ->
                    val delivered = _frameFlow.tryEmit(frame)
                    frameEmitStats(textureId, delivered)
                }
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

    /// Legacy-entry variant of the id-0 burn above (see openCamera).
    private fun createNonZeroSurfaceTexture(): TextureRegistry.SurfaceTextureEntry {
        var e = textureRegistry.createSurfaceTexture()
        if (e.id() == 0L) {
            val zero = e
            e = textureRegistry.createSurfaceTexture()
            runCatching { zero.release() }
        }
        return e
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
        session(textureId)?.stopVideoRecording()
            ?: RecordingResult("", 0L, 0L, 0L, 0L, 0L, 0L, 0L)

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
                    _devicesJsonCache = null
                    emitEvent(CameraEventType.DEVICECONNECTED, message = cameraId)
                }

                override fun onCameraUnavailable(cameraId: String) {
                    _cachedIds = null
                    _devicesJsonCache = null
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
}
