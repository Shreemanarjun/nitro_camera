package dev.shreeman.nitro_camera

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.HandlerThread
import android.hardware.camera2.params.MeteringRectangle
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import nitro.nitro_camera_module.*
import kotlin.coroutines.resumeWithException

/**
 * Real Camera2 implementation of HybridNitroCameraSpec.
 *
 * Preview renders GPU-accelerated via Flutter SurfaceTexture (zero CPU copy).
 * The optional frame processor delivers pixel data via [frameStream].
 */
@SuppressLint("LogNotTimber")
class NitroCameraImpl(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
) : HybridNitroCameraSpec {

    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main + kotlinx.coroutines.SupervisorJob())
    private val openLock = Mutex()

    private val cameraManager: CameraManager
        get() = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private val sessions = mutableMapOf<Long, NitraCameraSession>()
    private val sessionsLock = Any()

    private val openThread = HandlerThread("NitraCameraOpen").also { it.start() }
    private val openHandler = Handler(openThread.looper)

    private val _frameFlow = MutableSharedFlow<CameraFrame>(extraBufferCapacity = 2)
    override val frameStream: Flow<CameraFrame> = _frameFlow.asSharedFlow()

    @Volatile
    var activity: android.app.Activity? = null

    companion object {
        const val PERMISSION_REQUEST_CODE = 9921
    }

    // ---- Permissions ----

    private var pendingCameraDeferred: kotlinx.coroutines.CompletableDeferred<Long>? = null
    private var pendingMicDeferred:    kotlinx.coroutines.CompletableDeferred<Long>? = null

    override suspend fun requestCameraPermission(): Long {
        if (getCameraPermissionStatus() == 1L) return 1L
        val act = activity ?: return 2L

        val deferred = kotlinx.coroutines.CompletableDeferred<Long>()
        pendingCameraDeferred = deferred
        
        androidx.core.app.ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.CAMERA),
            PERMISSION_REQUEST_CODE
        )
        
        return deferred.await()
    }

    override suspend fun getCameraPermissionStatus(): Long {
        return checkPermission(Manifest.permission.CAMERA)
    }

    override suspend fun requestMicrophonePermission(): Long {
        if (getMicrophonePermissionStatus() == 1L) return 1L
        val act = activity ?: return 2L

        val deferred = kotlinx.coroutines.CompletableDeferred<Long>()
        pendingMicDeferred = deferred

        androidx.core.app.ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST_CODE + 1
        )
        return deferred.await()
    }

    fun handlePermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) 1L else 2L
            pendingCameraDeferred?.complete(status)
            pendingCameraDeferred = null
            return true
        }
        if (requestCode == PERMISSION_REQUEST_CODE + 1) {
            val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) 1L else 2L
            pendingMicDeferred?.complete(status)
            pendingMicDeferred = null
            return true
        }
        return false
    }

    override suspend fun getMicrophonePermissionStatus(): Long {
        return checkPermission(Manifest.permission.RECORD_AUDIO)
    }

    private fun checkPermission(permission: String): Long {
        val granted = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        val status = if (granted) 1L else 2L
        android.util.Log.d("NitroCamera", "checkPermission($permission): $status")
        return status
    }

    // ---- Device enumeration ----

    override suspend fun getDeviceCount(): Long {
        val count = cameraManager.cameraIdList.size.toLong()
        android.util.Log.d("NitroCamera", "getDeviceCount: $count")
        return count
    }

    override suspend fun getDevice(index: Long): CameraDevice {
        val ids = cameraManager.cameraIdList
        android.util.Log.d("NitroCamera", "getDevice($index) from ${ids.size} devices")
        require(index >= 0 && index < ids.size) { "Camera index $index out of range" }
        return buildCameraDevice(ids[index.toInt()])
    }

    // ---- Camera lifecycle ----

    @SuppressLint("MissingPermission")
    override suspend fun openCamera(
        deviceId: String, width: Long, height: Long, fps: Long, enableAudio: Long
    ): Long = openLock.withLock {
        // 1. Pre-check permissions immediately on caller thread
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
             throw SecurityException("Camera permission not granted.")
        }

        // 2. Perform UI-linked registry work on Main thread
        val textureEntry = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
            textureRegistry.createSurfaceTexture()
        }
        val textureId = textureEntry.id()

        // 3. Perform blocking open on background dispatcher
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
             val deferred = kotlinx.coroutines.CompletableDeferred<Long>()
             android.os.Handler(android.os.Looper.getMainLooper()).post {
                 try {
                     android.util.Log.d("NitroCamera", "Initiating openCamera($deviceId) on Texture $textureId")
                     cameraManager.openCamera(
                        deviceId,
                        object : android.hardware.camera2.CameraDevice.StateCallback() {
                            override fun onOpened(camera: android.hardware.camera2.CameraDevice) {
                                try {
                                    val session = NitraCameraSession(
                                        context      = context,
                                        textureEntry = textureEntry,
                                        textureId    = textureId,
                                        cameraDevice = camera,
                                        width        = width.toInt(),
                                        height       = height.toInt(),
                                        fps          = fps.toInt(),
                                        enableAudio  = enableAudio != 0L
                                    )
                                    session.onFrame = { frame -> _frameFlow.tryEmit(frame) }
                                    synchronized(sessionsLock) { sessions[textureId] = session }
                                    session.startPreview()
                                    deferred.complete(textureId)
                                } catch (e: Exception) {
                                    camera.close()
                                    textureEntry.release()
                                    deferred.completeExceptionally(e)
                                }
                            }

                            override fun onDisconnected(camera: android.hardware.camera2.CameraDevice) {
                                camera.close()
                                deferred.completeExceptionally(Exception("Disconnected"))
                            }

                            override fun onError(camera: android.hardware.camera2.CameraDevice, error: Int) {
                                camera.close()
                                deferred.completeExceptionally(Exception("Hardware error $error"))
                            }
                        },
                        openHandler
                    )
                 } catch (e: Exception) {
                     deferred.completeExceptionally(e)
                 }
             }
             kotlinx.coroutines.withTimeout(5000) { deferred.await() }
        }
    }

    override suspend fun closeCamera(textureId: Long) = openLock.withLock {
        val s = synchronized(sessionsLock) { sessions.remove(textureId) } ?: return
        
        android.util.Log.d("NitroCamera", "Closing session for texture $textureId")
        
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
             val deferred = kotlinx.coroutines.CompletableDeferred<Unit>()
             android.os.Handler(android.os.Looper.getMainLooper()).post {
                 try {
                     s.close()
                     deferred.complete(Unit)
                 } catch (e: Exception) {
                     android.util.Log.e("NitroCamera", "Error closing session: ${e.message}")
                     deferred.complete(Unit) // Still finalize
                 }
             }
             kotlinx.coroutines.withTimeout(3000) { deferred.await() }
        }
    }

    override suspend fun startPreview(textureId: Long) { session(textureId)?.startPreview() }
    override suspend fun stopPreview(textureId: Long)  { session(textureId)?.stopPreview()  }

    // ---- Camera controls ----

    override suspend fun setZoom(textureId: Long, zoom: Double)           { session(textureId)?.setZoom(zoom) }
    override suspend fun setFocusPoint(textureId: Long, x: Double, y: Double) { session(textureId)?.setFocusPoint(x, y) }
    override suspend fun setAutoFocus(textureId: Long, mode: Long)         { session(textureId)?.setAutoFocus(mode) }
    override suspend fun setExposure(textureId: Long, value: Double)       { session(textureId)?.setExposure(value) }
    override suspend fun setFlash(textureId: Long, mode: Long)             { session(textureId)?.setFlash(mode) }
    override suspend fun setTorch(textureId: Long, enabled: Long)          { session(textureId)?.setTorch(enabled != 0L) }
    override suspend fun setWhiteBalance(textureId: Long, temperature: Long) { session(textureId)?.setWhiteBalance(temperature) }
    override suspend fun setHdr(textureId: Long, enabled: Long)            { session(textureId)?.setHdr(enabled != 0L) }

    // ---- Photo capture ----

    override suspend fun takePhoto(textureId: Long): PhotoResult {
        val s = session(textureId) ?: error("No active camera session for textureId=$textureId")
        return s.takePhoto()
    }

    // ---- Video recording ----

    override suspend fun startVideoRecording(textureId: Long, outputPath: String) {
        session(textureId)?.startVideoRecording(outputPath)
    }

    override suspend fun stopVideoRecording(textureId: Long): RecordingResult =
        session(textureId)?.stopVideoRecording() ?: RecordingResult("", 0L, 0L)

    // ---- Frame processing ----
    
    override suspend fun setFrameFormat(textureId: Long, format: Long) {
        session(textureId)?.setFrameFormat(format)
    }

    override suspend fun setFilterShader(textureId: Long, shaderSource: String) {
        session(textureId)?.setFilterShader(shaderSource)
    }

    override suspend fun updateOverlay(textureId: Long, overlayData: String) {
        // Reserved for future GPU-overlays (vectors/text)
        Log.d("NitroCamera", "updateOverlay called for texture $textureId")
    }

    override suspend fun enableFrameProcessing(textureId: Long, enabled: Long) {
        session(textureId)?.frameProcessingEnabled = (enabled != 0L)
    }

    // ---- Helpers ----

    private fun session(textureId: Long) = synchronized(sessionsLock) { sessions[textureId] }

    private fun buildCameraDevice(cameraId: String): CameraDevice {
        val chars    = cameraManager.getCameraCharacteristics(cameraId)
        val facing   = chars.get(CameraCharacteristics.LENS_FACING)
        val position = when (facing) {
            CameraCharacteristics.LENS_FACING_FRONT -> 0L
            CameraCharacteristics.LENS_FACING_BACK  -> 1L
            else                                     -> 2L
        }
        val orientation = (chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0).toLong()
        val maxZoom     = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        val hasFlash    = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

        val map   = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(android.graphics.ImageFormat.JPEG)?.sortedByDescending { it.width }
        val maxW  = sizes?.firstOrNull()?.width?.toLong() ?: 1920L
        val maxH  = sizes?.firstOrNull()?.height?.toLong() ?: 1080L

        val focal     = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val lensType  = when {
            focal == null || focal.isEmpty() -> 0L
            focal[0] < 2.0f  -> 2L  // ultra-wide
            focal[0] > 5.0f  -> 3L  // telephoto
            else              -> 1L  // wide
        }

        return CameraDevice(
            id                = cameraId,
            name              = "Camera $cameraId",
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
