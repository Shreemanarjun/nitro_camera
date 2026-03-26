package dev.shreeman.nitro_camera

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Range
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import nitro.nitro_camera_module.CameraDevice
import nitro.nitro_camera_module.CameraFrame
import nitro.nitro_camera_module.HybridNitroCameraSpec
import nitro.nitro_camera_module.PhotoResult
import nitro.nitro_camera_module.RecordingResult
import org.json.JSONArray
import org.json.JSONObject

/**
 * Camera2 implementation of [HybridNitroCameraSpec].
 *
 * Preview: camera → Flutter SurfaceTexture → Texture(textureId).
 * Zero CPU copy on the hot path; EGL not used for preview.
 */
@SuppressLint("LogNotTimber", "MissingPermission")
class NitroCameraImpl(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
) : HybridNitroCameraSpec {

    private val cameraManager: CameraManager
        get() = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private val sessions     = mutableMapOf<Long, NitraCameraSession>()
    private val sessionsLock = Any()

    // Dedicated thread for Camera2 callbacks — never blocks the UI thread
    private val openThread  = HandlerThread("NitraCameraOpen").also { it.start() }
    private val openHandler = Handler(openThread.looper)

    private val _frameFlow = MutableSharedFlow<CameraFrame>(extraBufferCapacity = 8)
    override val frameStream: Flow<CameraFrame> = _frameFlow.asSharedFlow()

    // Activity reference — set by NitroCameraPlugin for permission requests
    @Volatile var activity: android.app.Activity? = null

    companion object {
        private const val PERM_CAMERA = 9921
        private const val PERM_MIC    = 9922
        private const val TAG         = "NitroCamera"
    }

    private var pendingCameraDeferred: CompletableDeferred<Long>? = null
    private var pendingMicDeferred:    CompletableDeferred<Long>? = null

    // ---- Permissions --------------------------------------------------------

    override suspend fun requestCameraPermission(): Long {
        if (getCameraPermissionStatus() == 1L) return 1L
        val act = activity ?: return 2L
        val def = CompletableDeferred<Long>()
        pendingCameraDeferred = def
        ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.CAMERA), PERM_CAMERA)
        return def.await()
    }

    override suspend fun getCameraPermissionStatus(): Long =
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED) 1L else 2L

    override suspend fun requestMicrophonePermission(): Long {
        if (getMicrophonePermissionStatus() == 1L) return 1L
        val act = activity ?: return 2L
        val def = CompletableDeferred<Long>()
        pendingMicDeferred = def
        ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.RECORD_AUDIO), PERM_MIC)
        return def.await()
    }

    override suspend fun getMicrophonePermissionStatus(): Long =
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED) 1L else 2L

    fun handlePermissionResult(code: Int, grantResults: IntArray): Boolean {
        val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) 1L else 2L
        return when (code) {
            PERM_CAMERA -> { pendingCameraDeferred?.complete(status); pendingCameraDeferred = null; true }
            PERM_MIC    -> { pendingMicDeferred?.complete(status);    pendingMicDeferred    = null; true }
            else        -> false
        }
    }

    // ---- Device enumeration -------------------------------------------------

    override suspend fun getAvailableCameraDevicesJson(): String {
        val ids = cameraManager.cameraIdList
        val arr = JSONArray()
        for (id in ids) {
            try { arr.put(buildCameraDeviceJson(id)) } catch (_: Exception) {}
        }
        return arr.toString()
    }

    override suspend fun getDeviceCount(): Long = cameraManager.cameraIdList.size.toLong()

    override suspend fun getDevice(index: Long): CameraDevice {
        val ids = cameraManager.cameraIdList
        require(index in 0 until ids.size) { "Camera index $index out of range (${ids.size} devices)" }
        return buildCameraDevice(ids[index.toInt()])
    }

    // ---- Camera lifecycle ---------------------------------------------------

    override suspend fun openCamera(
        deviceId: String, width: Long, height: Long, fps: Long, enableAudio: Long,
    ): Long {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) throw SecurityException("Camera permission not granted")

        // Register Flutter texture on the main thread (required by Flutter engine)
        val textureEntry = withContext(Dispatchers.Main) { textureRegistry.createSurfaceTexture() }
        val textureId = textureEntry.id()

        // VALIDATE DeviceID before hitting the JNI layer to prevent pending exceptions
        val availableIds = cameraManager.cameraIdList.toList()
        if (!availableIds.contains(deviceId)) {
            Log.e(TAG, "Unknown camera device $deviceId. Available: ${availableIds.joinToString()}.")
            withContext(Dispatchers.Main) { 
                try { textureEntry.release() } catch (_: Exception) {}
            }
            return 0L // Graceful failure instead of crash
        }
        
        // Ensure we can get characteristics without throwing
        try {
            cameraManager.getCameraCharacteristics(deviceId)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get characteristics for $deviceId: ${e.message}")
            withContext(Dispatchers.Main) { 
                try { textureEntry.release() } catch (_: Exception) {}
            }
            return 0L
        }

        try {
            // Open camera on openHandler; suspendCancellableCoroutine resumes when callback fires
            val camera = suspendCancellableCoroutine { cont ->
                cont.invokeOnCancellation { 
                    Handler(Looper.getMainLooper()).post { 
                        try { textureEntry.release() } catch (_: Exception) {}
                    }
                }
                
                try {
                    cameraManager.openCamera(
                        deviceId,
                        object : android.hardware.camera2.CameraDevice.StateCallback() {
                            override fun onOpened(cam: android.hardware.camera2.CameraDevice) {
                                if (cont.isActive) {
                                    // Use the onCancellation lambda to ensure cam is closed 
                                    // if the coroutine is cancelled after resumption
                                    cont.resume(cam) { cam.close() }
                                } else {
                                    cam.close()
                                }
                            }
                            override fun onDisconnected(cam: android.hardware.camera2.CameraDevice) {
                                cam.close()
                                if (cont.isActive) cont.cancel()
                            }
                            override fun onError(cam: android.hardware.camera2.CameraDevice, error: Int) {
                                Log.e(TAG, "Hardware onError: $error for $deviceId")
                                cam.close()
                                if (cont.isActive) {
                                    cont.resumeWith(Result.failure(Exception("Camera open error $error for $deviceId")))
                                }
                            }
                        },
                        openHandler,
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "cameraManager.openCamera exception: ${e.message}")
                    if (cont.isActive) cont.resumeWith(Result.failure(e))
                }
            }

            val session = NitraCameraSession(
                context      = context,
                textureEntry = textureEntry,
                textureId    = textureId,
                cameraDevice = camera,
                width        = width.toInt(),
                height       = height.toInt(),
                requestedFps = fps.toInt(),
                enableAudio  = enableAudio != 0L,
            )
            session.onFrame = { frame -> _frameFlow.tryEmit(frame) }
            synchronized(sessionsLock) { sessions[textureId] = session }

            // Non-blocking — camera session is configured via async Camera2 callbacks
            session.startPreview()

            Log.d(TAG, "openCamera($deviceId) → textureId=$textureId")
            return textureId
        } catch (e: Exception) {
            Log.e(TAG, "General openCamera failure: ${e.message}")
            withContext(Dispatchers.Main) { 
                try { textureEntry.release() } catch (_: Exception) {}
            }
            return 0L // Graceful failure - never throw to Nitrogen bridge
        }
    }

    override suspend fun closeCamera(textureId: Long) {
        val s = synchronized(sessionsLock) { sessions.remove(textureId) } ?: return
        Log.d(TAG, "closeCamera(textureId=$textureId)")
        // Close on IO to avoid blocking the calling coroutine
        withContext(Dispatchers.IO) { s.close() }
    }

    override suspend fun startPreview(textureId: Long) { session(textureId)?.startPreview() }
    override suspend fun stopPreview(textureId: Long)  { session(textureId)?.stopPreview() }

    // ---- Camera controls ----------------------------------------------------

    override suspend fun setZoom(textureId: Long, zoom: Double)                { session(textureId)?.setZoom(zoom) }
    override suspend fun setFocusPoint(textureId: Long, x: Double, y: Double)  { session(textureId)?.setFocusPoint(x, y) }
    override suspend fun setAutoFocus(textureId: Long, mode: Long)              { session(textureId)?.setAutoFocus(mode) }
    override suspend fun setExposure(textureId: Long, value: Double)            { session(textureId)?.setExposure(value) }
    override suspend fun setFlash(textureId: Long, mode: Long)                  { session(textureId)?.setFlash(mode) }
    override suspend fun setTorch(textureId: Long, enabled: Long)               { session(textureId)?.setTorch(enabled != 0L) }
    override suspend fun setWhiteBalance(textureId: Long, temperature: Long)    { session(textureId)?.setWhiteBalance(temperature) }
    override suspend fun setHdr(textureId: Long, enabled: Long)                 { session(textureId)?.setHdr(enabled != 0L) }

    // ---- Photo / Video ------------------------------------------------------

    override suspend fun takePhoto(textureId: Long): PhotoResult =
        session(textureId)?.takePhoto() ?: error("No session for textureId=$textureId")

    override suspend fun startVideoRecording(textureId: Long, outputPath: String) {
        session(textureId)?.startVideoRecording(outputPath)
    }

    override suspend fun stopVideoRecording(textureId: Long): RecordingResult =
        session(textureId)?.stopVideoRecording() ?: RecordingResult("", 0L, 0L)

    override suspend fun pauseRecording(textureId: Long)  { session(textureId)?.pauseVideoRecording() }
    override suspend fun resumeRecording(textureId: Long) { session(textureId)?.resumeVideoRecording() }
    override suspend fun cancelRecording(textureId: Long) { session(textureId)?.cancelVideoRecording() }

    // ---- Frame processing ---------------------------------------------------

    override suspend fun enableFrameProcessing(textureId: Long, enabled: Long) {
        session(textureId)?.frameProcessingEnabled = (enabled != 0L)
    }

    override suspend fun setFrameFormat(textureId: Long, format: Long)            { session(textureId)?.setFrameFormat(format) }
    override suspend fun setFilterShader(textureId: Long, shaderSource: String)   { session(textureId)?.setFilterShader(shaderSource) }
    override suspend fun updateOverlay(textureId: Long, overlayData: String)      { /* reserved */ }

    // ---- Helpers ------------------------------------------------------------

    private fun session(textureId: Long) = synchronized(sessionsLock) { sessions[textureId] }

    // ---- Camera device info helpers -----------------------------------------

    private fun buildCameraDeviceJson(cameraId: String): JSONObject {
        val chars = cameraManager.getCameraCharacteristics(cameraId)

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

        val focal    = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val lensType = if (focal == null || focal.isEmpty()) 0
        else when {
            focal[0] < 2.3f -> 2  // ultra-wide
            focal[0] > 5.0f -> 3  // telephoto
            else             -> 1  // wide-angle
        }

        val lensName = when (lensType) { 2 -> "Ultra Wide" 3 -> "Telephoto" else -> "Wide" }
        val name     = if (position == 0) "Front Camera" else "$lensName Camera"

        val evRange  = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val evStep   = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toDouble() ?: 1.0
        val minEv    = if (evRange != null && evStep != 0.0) evRange.lower * evStep else -4.0
        val maxEv    = if (evRange != null && evStep != 0.0) evRange.upper * evStep else  4.0

        val minFocusDist = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
        // Camera2 focus distance is in diopters (1/m). Convert to cm: 100/diopters. 0 = infinity.
        val minFocusCm   = if (minFocusDist > 0f) (100.0 / minFocusDist) else 0.0

        val capabilities = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: intArrayOf()
        val supportsRaw  = capabilities.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW)
        val supportsDepth = capabilities.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT)

        val hwLevel = when (chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY  -> "legacy"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL    -> "full"
            else                                                          -> "limited"
        }

        val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val minISO   = isoRange?.lower?.toDouble() ?: 25.0
        val maxISO   = isoRange?.upper?.toDouble() ?: 3200.0

        val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: emptyArray()

        // Formats: one entry per unique video size (YUV_420_888), annotated with best FPS range
        val formatsArr = JSONArray()
        val videoSizes = map?.getOutputSizes(android.graphics.ImageFormat.YUV_420_888)
            ?.sortedByDescending { it.width * it.height } ?: emptyList()

        for (size in videoSizes) {
            // Best FPS range for this size
            val bestFps = fpsRanges.maxByOrNull { it.upper } ?: Range(1, 30)
            val fmt = JSONObject()
            fmt.put("photoWidth",  maxPhotoW)
            fmt.put("photoHeight", maxPhotoH)
            fmt.put("videoWidth",  size.width)
            fmt.put("videoHeight", size.height)
            fmt.put("minFps",      bestFps.lower.toDouble())
            fmt.put("maxFps",      bestFps.upper.toDouble())
            fmt.put("minISO",      minISO)
            fmt.put("maxISO",      maxISO)
            fmt.put("fieldOfView", focalLengthToFov(focal?.getOrNull(0), chars))
            fmt.put("supportsVideoHdr",    false)
            fmt.put("supportsPhotoHdr",    false)
            fmt.put("supportsDepthCapture", supportsDepth)
            fmt.put("autoFocusSystem", "phase-detection")
            fmt.put("videoStabilizationModes", JSONArray(listOf("off")))
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
            put("neutralZoom",         1.0)
            put("hasFlash",            hasFlash)
            put("hasTorch",            hasFlash)
            put("maxPhotoWidth",       maxPhotoW)
            put("maxPhotoHeight",      maxPhotoH)
            put("minExposure",         minEv)
            put("maxExposure",         maxEv)
            put("minFocusDistanceCm",  minFocusCm)
            put("isMultiCam",          false)
            put("supportsLowLightBoost", false)
            put("supportsRawCapture",  supportsRaw)
            put("supportsFocus",       true)
            put("hardwareLevel",       hwLevel)
            put("physicalDevices",     JSONArray(listOf(lensName.lowercase().replace(' ', '-') + "-camera")))
            put("formats",             formatsArr)
        }
    }

    private fun focalLengthToFov(focalMm: Float?, chars: CameraCharacteristics): Double {
        if (focalMm == null || focalMm <= 0f) return 69.4
        val sensorW = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)?.width ?: return 69.4
        return Math.toDegrees(2.0 * Math.atan(sensorW / (2.0 * focalMm)))
    }

    private fun buildCameraDevice(cameraId: String): CameraDevice {
        val chars = cameraManager.getCameraCharacteristics(cameraId)

        val position = when (chars.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_FRONT -> 0L
            CameraCharacteristics.LENS_FACING_BACK  -> 1L
            else                                     -> 2L
        }
        val orientation = (chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0).toLong()
        val maxZoom     = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        val hasFlash    = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

        val map   = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(android.graphics.ImageFormat.JPEG)?.sortedByDescending { it.width }
        val maxW  = sizes?.firstOrNull()?.width?.toLong()  ?: 1920L
        val maxH  = sizes?.firstOrNull()?.height?.toLong() ?: 1080L

        val focal    = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val lensType = if (focal == null || focal.isEmpty()) {
            0L
        } else {
            val f = focal[0]
            when {
                f < 2.3f -> 2L  // ultra-wide
                f > 5.0f -> 3L  // telephoto
                else     -> 1L  // wide-angle
            }
        }

        val lensName = when (lensType) { 2L -> "Ultra Wide" 3L -> "Telephoto" else -> "Wide" }
        val name     = if (position == 0L) "Front Camera" else "$lensName Camera"

        return CameraDevice(
            id                = cameraId,
            name              = name,
            position          = position,
            lensType          = lensType,
            sensorOrientation = orientation,
            minZoom           = 1.0,
            maxZoom           = maxZoom,
            neutralZoom       = 1.0,
            hasFlash          = if (hasFlash) 1L else 0L,
            hasTorch          = if (hasFlash) 1L else 0L,
            maxPhotoWidth     = maxW,
            maxPhotoHeight    = maxH,
        )
    }
}
