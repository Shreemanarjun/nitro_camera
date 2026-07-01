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
        val activeSessions = sessions.values.toList()
        sessions.clear()
        activeSessions.map { async { it.close() } }.awaitAll()
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
    }

    private var _cachedIds: List<String>? = null
    private fun getIds(): List<String> {
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

    private val hardwareLock = Mutex()

    @OptIn(ExperimentalCoroutinesApi::class)
    override suspend fun openCamera(
        deviceId: String, width: Long, height: Long, fps: Long, enableAudio: Long,
    ): Long {
        return hardwareLock.withLock {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) throw SecurityException("Camera permission not granted")

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
            val camera = suspendCancellableCoroutine { cont ->
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
            return@withLock textureId
        } catch (e: Exception) {
            Log.e(TAG, "General openCamera failure: ${e.message}")
            emitEvent(CameraEventType.ERROR, message = "openCamera failed: ${e.message}")
            withContext(Dispatchers.Main) {
                surfaceTextureEntry?.release()
                (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)?.release()
            }
            return 0L
        }
    }
}

    fun attachPlatformView(textureId: Long, surface: Surface) {
        session(textureId)?.attachPlatformSurface(surface)
    }

    fun detachPlatformView(textureId: Long) {
        session(textureId)?.detachPlatformSurface()
    }

    override suspend fun closeCamera(textureId: Long) {
        hardwareLock.withLock {
            val s = synchronized(sessionsLock) { sessions.remove(textureId) } ?: return@withLock
            withContext(Dispatchers.IO) { s.close() }
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

    override suspend fun startVideoRecording(textureId: Long, outputPath: String) {
        session(textureId)?.startVideoRecording(outputPath)
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
    override fun setTorchLevel(textureId: Long, level: Double)      { session(textureId)?.setTorchLevel(level) }
    override fun lockExposure(textureId: Long, locked: Long)        { session(textureId)?.lockExposure(locked != 0L) }
    override fun lockFocus(textureId: Long, locked: Long)           { session(textureId)?.lockFocus(locked != 0L) }
    override fun lockWhiteBalance(textureId: Long, locked: Long)    { session(textureId)?.lockWhiteBalance(locked != 0L) }
    override fun setTargetOrientation(textureId: Long, degrees: Long) { session(textureId)?.setTargetOrientation(degrees.toInt()) }

    override suspend fun takePhotoWithOptions(textureId: Long, options: PhotoOptions): PhotoResult {
        val s = session(textureId) ?: error("No session")
        s.setFlash(options.flash)
        return s.takePhoto()
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
        val maxZoom     = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        val hasFlash    = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

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

        val formatsArr = JSONArray()
        val videoSizes = map?.getOutputSizes(android.graphics.ImageFormat.YUV_420_888)
            ?.sortedByDescending { it.width * it.height } ?: emptyList()

        for (size in videoSizes) {
            val fmt = JSONObject()
            fmt.put("photoWidth",  maxPhotoW)
            fmt.put("photoHeight", maxPhotoH)
            fmt.put("videoWidth",  size.width)
            fmt.put("videoHeight", size.height)
            fmt.put("minFps",      15.0)
            fmt.put("maxFps",      30.0)
            formatsArr.put(fmt)
        }

        return JSONObject().apply {
            put("id",                  cameraId)
            put("name",                name)
            put("position",            position)
            put("lensType",            lensType)
            put("sensorOrientation",   orientation)
            put("minZoom",             1.0)
            put("maxZoom",             maxZoom)
            put("hasFlash",            hasFlash)
            put("maxPhotoWidth",       maxPhotoW)
            put("maxPhotoHeight",      maxPhotoH)
            put("minExposure",         minEv)
            put("maxExposure",         maxEv)
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
