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

class NitroCameraImpl(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
) : HybridNitroCameraSpec, DefaultLifecycleObserver {

    var activity: android.app.Activity? = null

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


    fun handlePermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        return false
    }

    override suspend fun reset() {
        coroutineScope {
            closeAll()
        }
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

    override suspend fun getCameraPermissionStatus(): Long {
        return if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED) 1L else 2L
    }

    override suspend fun requestCameraPermission(): Long {
        return getCameraPermissionStatus()
    }

    override suspend fun getMicrophonePermissionStatus(): Long = 1L
    override suspend fun requestMicrophonePermission(): Long = 1L

    override suspend fun getDeviceCount(): Long = getIds().size.toLong()

    override suspend fun getAvailableCameraDevicesJson(): String {
        val arr = JSONArray()
        for (id in getIds()) {
            arr.put(buildCameraDeviceJson(id, getCharacteristics(id)))
        }
        return arr.toString()
    }

    override suspend fun getAvailableCameraDevices(): List<CameraDevice> {
        return getIds().map { id -> buildCameraDevice(id, getCharacteristics(id)) }
    }

    override suspend fun getDevice(index: Long): CameraDevice {
        val ids = getIds()
        if (index < 0 || index >= ids.size) throw Exception("Camera index out of bounds")
        val id = ids[index.toInt()]
        return buildCameraDevice(id, getCharacteristics(id))
    }

    private val hardwareLock = Mutex()

    @OptIn(ExperimentalCoroutinesApi::class)
    override suspend fun openCamera(
        deviceId: String, width: Long, height: Long, fps: Long, enableAudio: Long,
    ): Long = hardwareLock.withLock {
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
            synchronized(sessionsLock) { sessions[textureId] = session }

            session.startPreview()
            return textureId
        } catch (e: Exception) {
            Log.e(TAG, "General openCamera failure: ${e.message}")
            withContext(Dispatchers.Main) {
                surfaceTextureEntry?.release()
                (surfaceProducer as? io.flutter.view.TextureRegistry.SurfaceProducer)?.release()
            }
            return 0L
        }
    }

    override suspend fun closeCamera(textureId: Long) = hardwareLock.withLock {
        val s = synchronized(sessionsLock) { sessions.remove(textureId) } ?: return@withLock
        withContext(Dispatchers.IO) { s.close() }
    }

    override suspend fun startPreview(textureId: Long) { session(textureId)?.startPreview() }
    override suspend fun stopPreview(textureId: Long)  { session(textureId)?.stopPreview() }

    override suspend fun setZoom(textureId: Long, zoom: Double)                { session(textureId)?.setZoom(zoom) }
    override suspend fun setFocusPoint(textureId: Long, x: Double, y: Double)  { session(textureId)?.setFocusPoint(x, y) }
    override suspend fun setAutoFocus(textureId: Long, mode: Long)              { session(textureId)?.setAutoFocus(mode) }
    override suspend fun setExposure(textureId: Long, value: Double)            { session(textureId)?.setExposure(value) }
    override suspend fun setFlash(textureId: Long, mode: Long)                  { session(textureId)?.setFlash(mode) }
    override suspend fun setTorch(textureId: Long, enabled: Long)               { session(textureId)?.setTorch(enabled != 0L) }
    override suspend fun setWhiteBalance(textureId: Long, temperature: Long)    { session(textureId)?.setWhiteBalance(temperature) }
    override suspend fun setHdr(textureId: Long, enabled: Long)                 { session(textureId)?.setHdr(enabled != 0L) }

    override suspend fun takePhoto(textureId: Long): PhotoResult =
        session(textureId)?.takePhoto() ?: error("No session")

    override suspend fun startVideoRecording(textureId: Long, outputPath: String) {
        session(textureId)?.startVideoRecording(outputPath)
    }

    override suspend fun stopVideoRecording(textureId: Long): RecordingResult =
        session(textureId)?.stopVideoRecording() ?: RecordingResult("", 0L, 0L)

    override suspend fun pauseRecording(textureId: Long)  { session(textureId)?.pauseVideoRecording() }
    override suspend fun resumeRecording(textureId: Long) { session(textureId)?.resumeVideoRecording() }
    override suspend fun cancelRecording(textureId: Long) { session(textureId)?.cancelVideoRecording() }

    override suspend fun enableFrameProcessing(textureId: Long, enabled: Long) {
        session(textureId)?.frameProcessingEnabled = (enabled != 0L)
    }

    override suspend fun setFrameFormat(textureId: Long, format: Long)            { session(textureId)?.setFrameFormat(format) }
    override suspend fun setSamplingRate(textureId: Long, samplingRate: Long)      { session(textureId)?.setSamplingRate(samplingRate) }
    override suspend fun setFilterShader(textureId: Long, shaderSource: String)   { session(textureId)?.setFilterShader(shaderSource) }
    override suspend fun updateOverlay(textureId: Long, overlayData: java.nio.ByteBuffer)      { /* reserved */ }

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
