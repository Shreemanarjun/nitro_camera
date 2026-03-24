package dev.shreeman.nitro_camera

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CompletableDeferred
import nitro.nitro_camera_module.*

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

        try {
            // Open camera on openHandler; suspendCancellableCoroutine resumes when callback fires
            val camera = suspendCancellableCoroutine { cont ->
                cont.invokeOnCancellation { textureEntry.release() }
                cameraManager.openCamera(
                    deviceId,
                    object : android.hardware.camera2.CameraDevice.StateCallback() {
                        override fun onOpened(cam: android.hardware.camera2.CameraDevice) =
                            cont.resumeWith(Result.success(cam))
                        override fun onDisconnected(cam: android.hardware.camera2.CameraDevice) {
                            cam.close(); cont.cancel()
                        }
                        override fun onError(cam: android.hardware.camera2.CameraDevice, error: Int) {
                            cam.close()
                            cont.resumeWith(Result.failure(Exception("Camera open error $error for $deviceId")))
                        }
                    },
                    openHandler,
                )
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
            textureEntry.release()
            throw e
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

    // ---- Frame processing ---------------------------------------------------

    override suspend fun enableFrameProcessing(textureId: Long, enabled: Long) {
        session(textureId)?.frameProcessingEnabled = (enabled != 0L)
    }

    override suspend fun setFrameFormat(textureId: Long, format: Long)            { session(textureId)?.setFrameFormat(format) }
    override suspend fun setFilterShader(textureId: Long, shaderSource: String)   { session(textureId)?.setFilterShader(shaderSource) }
    override suspend fun updateOverlay(textureId: Long, overlayData: String)      { /* reserved */ }

    // ---- Helpers ------------------------------------------------------------

    private fun session(textureId: Long) = synchronized(sessionsLock) { sessions[textureId] }

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

        // Lens type heuristic from focal length
        val focal    = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val lensType = if (focal == null || focal.size == 0) {
            0L
        } else {
            val f = focal[0]
            when {
                f < 2.3f -> 2L  // ultra-wide
                f > 5.0f -> 3L  // telephoto
                else     -> 1L  // wide-angle
            }
        }

        // Best name: use lens type + position
        val posName  = if (position == 0L) "Front" else if (position == 1L) "Back" else "External"
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
