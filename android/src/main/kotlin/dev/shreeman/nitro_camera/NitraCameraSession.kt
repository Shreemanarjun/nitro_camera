package dev.shreeman.nitro_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.*
import android.hardware.camera2.params.MeteringRectangle
import android.media.Image
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Rational
import android.view.Surface
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.suspendCancellableCoroutine
import nitro.nitro_camera_module.*
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.resume

// Alias to avoid conflict with Nitrogen-generated CameraDevice struct
import android.hardware.camera2.CameraDevice as AndroidCameraDevice

/**
 * Manages a single camera session for a specific texture.
 */
class NitraCameraSession(
    private val context: Context,
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    val textureId: Long,
    private val cameraDevice: AndroidCameraDevice,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val enableAudio: Boolean,
) {
    private val cameraThread = HandlerThread("NitraCameraThread-$textureId").also { it.start() }
    private val cameraHandler = Handler(cameraThread.looper)

    private val surfaceTexture = textureEntry.surfaceTexture().apply {
        setDefaultBufferSize(width, height)
    }
    private val previewSurface = Surface(surfaceTexture)

    @Volatile
    private var isClosed = false
    private val stateLock = Any()

    // Photo capture (JPEG) - Use max resolution
    private val photoReader: ImageReader by lazy {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val chars = manager.getCameraCharacteristics(cameraDevice.id)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.JPEG)?.sortedByDescending { it.width * it.height }
        val size = sizes?.firstOrNull() ?: android.util.Size(width, height)
        Log.d("NitroCamera", "NitraCameraSession: PhotoReader initialized with ${size.width}x${size.height}")
        ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
    }

    // Video recording
    private var mediaRecorder: MediaRecorder? = null
    private var recordingStartMs = 0L
    private var recordingOutputPath = ""
    private var isRecording = false

    // Active capture session
    private var captureSession: CameraCaptureSession? = null
    private var previewRequest: CaptureRequest? = null

    // Frame processing (CPU path)
    var frameProcessingEnabled = false
    var onFrame: ((CameraFrame) -> Unit)? = null
    private val frameReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2)

    // Camera characteristics
    private val characteristics: CameraCharacteristics by lazy {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        manager.getCameraCharacteristics(cameraDevice.id)
    }

    // ---- Lifecycle ----

    @SuppressLint("MissingPermission")
    fun startPreview() {
        synchronized(stateLock) {
            if (isClosed) return
            isRecording = false
            Log.d("NitroCamera", "NitraCameraSession: Starting preview (frameProcessing: $frameProcessingEnabled)")
            
            val surfaces = mutableListOf<Surface>(previewSurface, photoReader.surface)
            if (frameProcessingEnabled) surfaces.add(frameReader.surface)

            try {
                cameraDevice.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        synchronized(stateLock) {
                            if (isClosed || isRecording) {
                                session.close()
                                return
                            }
                            Log.d("NitroCamera", "NitraCameraSession: Preview session configured")
                            captureSession = session
                            try {
                                val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_PREVIEW)
                                builder.addTarget(previewSurface)
                                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                                previewRequest = builder.build()
                                session.setRepeatingRequest(previewRequest!!, null, cameraHandler)
                            } catch (e: Exception) {
                                Log.e("NitroCamera", "NitraCameraSession: Failed to set preview repeating request: ${e.message}")
                            }
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e("NitroCamera", "NitraCameraSession: Preview session configuration failed")
                    }
                }, cameraHandler)
            } catch (e: Exception) {
                Log.e("NitroCamera", "NitraCameraSession: Failed to create preview capture session: ${e.message}")
            }
        }

        // Frame processor listener
        frameReader.setOnImageAvailableListener({ reader ->
            if (isClosed) return@setOnImageAvailableListener
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                if (frameProcessingEnabled) {
                    emitFrame(image)
                }
            } catch (e: Exception) {
                Log.e("NitroCamera", "NitraCameraSession: Frame processing error: ${e.message}")
            } finally {
                image.close()
            }
        }, cameraHandler)
    }

    fun stopPreview() {
        try {
            captureSession?.stopRepeating()
        } catch (e: Exception) {
            Log.w("NitroCamera", "NitraCameraSession: Error stopping preview: ${e.message}")
        }
    }

    fun close() {
        synchronized(stateLock) {
            if (isClosed) return
            isClosed = true
            Log.d("NitroCamera", "NitraCameraSession: Closing session for texture $textureId")
            try {
                captureSession?.stopRepeating()
                captureSession?.close()
            } catch (e: Exception) {
                Log.w("NitroCamera", "NitraCameraSession: Error while closing session: ${e.message}")
            }
            captureSession = null
            try {
                cameraDevice.close()
            } catch (e: Exception) {
                Log.w("NitroCamera", "NitraCameraSession: Error while closing camera device: ${e.message}")
            }
            previewSurface.release()
            surfaceTexture.release()
            photoReader.close()
            frameReader.close()
            textureEntry.release()
            cameraThread.quitSafely()
        }
    }

    // ---- Camera controls ----

    fun setZoom(zoom: Double) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            if (isRecording && mediaRecorder != null) builder.addTarget(mediaRecorder!!.surface)
            
            val maxZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
            val currentZoom = zoom.coerceIn(1.0, maxZoom.toDouble()).toFloat()
            
            val centerX = rect.width() / 2
            val centerY = rect.height() / 2
            val deltaX = (rect.width() / (2 * currentZoom)).toInt()
            val deltaY = (rect.height() / (2 * currentZoom)).toInt()
            
            val cropRect = Rect(centerX - deltaX, centerY - deltaY, centerX + deltaX, centerY + deltaY)
            builder.set(CaptureRequest.SCALER_CROP_REGION, cropRect)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set zoom: ${e.message}")
        }
    }

    fun setFocusPoint(x: Double, y: Double) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            
            val areaWidth = 200
            val areaHeight = 200
            val focusX = (x * rect.width()).toInt().coerceIn(areaWidth, rect.width() - areaWidth)
            val focusY = (y * rect.height()).toInt().coerceIn(areaHeight, rect.height() - areaHeight)
            
            val focusRect = Rect(focusX - areaWidth/2, focusY - areaHeight/2, focusX + areaWidth/2, focusY + areaHeight/2)
            val metering = MeteringRectangle(focusRect, MeteringRectangle.METERING_WEIGHT_MAX)
            
            builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(metering))
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
            
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set focus: ${e.message}")
        }
    }

    fun setAutoFocus(mode: Long) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            val afMode = when (mode) {
                0L -> CaptureRequest.CONTROL_AF_MODE_OFF
                1L -> CaptureRequest.CONTROL_AF_MODE_AUTO
                2L -> CaptureRequest.CONTROL_AF_MODE_MACRO
                3L -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
                else -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            }
            builder.set(CaptureRequest.CONTROL_AF_MODE, afMode)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set AF mode: ${e.message}")
        }
    }

    fun setExposure(value: Double) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            val range = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE) ?: return
            val step = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP) ?: Rational(1, 1)
            val ev = (value / step.toDouble()).toInt().coerceIn(range.lower, range.upper)
            builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, ev)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set exposure: ${e.message}")
        }
    }

    fun setFlash(mode: Long) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            val aeMode = when (mode) {
                0L -> CaptureRequest.CONTROL_AE_MODE_ON
                1L -> CaptureRequest.CONTROL_AE_MODE_ON_ALWAYS_FLASH
                2L -> CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH
                else -> CaptureRequest.CONTROL_AE_MODE_ON
            }
            builder.set(CaptureRequest.CONTROL_AE_MODE, aeMode)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set flash: ${e.message}")
        }
    }

    fun setTorch(enabled: Boolean) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            builder.set(CaptureRequest.FLASH_MODE,
                if (enabled) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set torch: ${e.message}")
        }
    }

    fun setWhiteBalance(temperature: Long) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            if (temperature == 0L) {
                builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
            } else {
                builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_OFF)
            }
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set AWB: ${e.message}")
        }
    }

    fun setHdr(enabled: Boolean) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val builder = cameraDevice.createCaptureRequest(if (isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface)
            if (enabled) {
                builder.set(CaptureRequest.CONTROL_SCENE_MODE, CaptureRequest.CONTROL_SCENE_MODE_HDR)
                builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_USE_SCENE_MODE)
            } else {
                builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            }
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to set HDR: ${e.message}")
        }
    }

    // ---- Photo capture ----

    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun takePhoto(): PhotoResult = suspendCancellableCoroutine { cont ->
        if (isClosed) {
            cont.resumeWithException(Exception("Session is closed"))
            return@suspendCancellableCoroutine
        }
        val session = captureSession ?: run {
            cont.resumeWithException(Exception("No active session"))
            return@suspendCancellableCoroutine
        }

        Log.d("NitroCamera", "NitraCameraSession: Preparing photo capture...")
        photoReader.setOnImageAvailableListener({ reader ->
            Log.d("NitroCamera", "NitraCameraSession: Image available in photoReader")
            val image = reader.acquireNextImage() ?: run {
                if (cont.isActive) cont.resumeWithException(Exception("No image acquired"))
                return@setOnImageAvailableListener
            }
            try {
                val buffer: ByteBuffer = image.planes[0].buffer
                val bytes = ByteArray(buffer.remaining())
                buffer.get(bytes)
                
                val imgWidth = image.width.toLong()
                val imgHeight = image.height.toLong()
                image.close()

                val tmp = File(context.cacheDir, "cap_${System.currentTimeMillis()}.jpg")
                FileOutputStream(tmp).use { it.write(bytes) }
                Log.d("NitroCamera", "NitraCameraSession: Photo saved to ${tmp.absolutePath}")

                if (cont.isActive) {
                    cont.resume(PhotoResult(
                        path     = tmp.absolutePath,
                        width    = imgWidth,
                        height   = imgHeight,
                        fileSize = bytes.size.toLong()
                    ))
                }
            } catch (e: Exception) {
                Log.e("NitroCamera", "NitraCameraSession: Photo save failed: ${e.message}")
                image.close()
                if (cont.isActive) cont.resumeWithException(e)
            } finally {
                reader.setOnImageAvailableListener(null, null)
            }
        }, cameraHandler)

        try {
            val captureBuilder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_STILL_CAPTURE)
            captureBuilder.addTarget(photoReader.surface)
            captureBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            captureBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            captureBuilder.set(CaptureRequest.JPEG_ORIENTATION, characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0)
            session.capture(captureBuilder.build(), null, cameraHandler)
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: Failed to trigger still capture: ${e.message}")
            if (cont.isActive) cont.resumeWithException(e)
        }
    }

    // ---- Video recording ----

    fun startVideoRecording(outputPath: String) {
        synchronized(stateLock) {
            if (isClosed) return
            isRecording = true
            recordingOutputPath = outputPath
            recordingStartMs = System.currentTimeMillis()

            try {
                val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    MediaRecorder(context)
                } else {
                    @Suppress("DEPRECATION")
                    MediaRecorder()
                }
                if (enableAudio) recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
                recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
                recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                if (enableAudio) recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                recorder.setVideoSize(width, height)
                recorder.setVideoFrameRate(30)
                recorder.setVideoEncodingBitRate(10_000_000)
                recorder.setOutputFile(outputPath)
                recorder.prepare()

                mediaRecorder = recorder
                val recSurface = recorder.surface

                val surfaces = mutableListOf(previewSurface, recSurface, photoReader.surface)
                cameraDevice.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        synchronized(stateLock) {
                            if (isClosed || !isRecording) {
                                session.close()
                                return
                            }
                            captureSession = session
                            try {
                                val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_RECORD)
                                builder.addTarget(previewSurface)
                                builder.addTarget(recSurface)
                                session.setRepeatingRequest(builder.build(), null, cameraHandler)
                                recorder.start()
                                Log.d("NitroCamera", "NitraCameraSession: Video recording started")
                            } catch (e: Exception) {
                                Log.e("NitroCamera", "NitraCameraSession: Failed to start recording: ${e.message}")
                            }
                        }
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e("NitroCamera", "NitraCameraSession: Video session config failed")
                    }
                }, cameraHandler)
            } catch (e: Exception) {
                Log.e("NitroCamera", "NitraCameraSession: Failed to prepare MediaRecorder: ${e.message}")
            }
        }
    }

    fun stopVideoRecording(): RecordingResult {
        synchronized(stateLock) {
            val recorder = mediaRecorder ?: return RecordingResult("", 0L, 0L)
            Log.d("NitroCamera", "NitraCameraSession: Stopping video recording...")
            try {
                recorder.stop()
            } catch (e: Exception) {
                Log.e("NitroCamera", "NitraCameraSession: Error stopping MediaRecorder: ${e.message}")
            }
            recorder.release()
            mediaRecorder = null
            isRecording = false

            val path = recordingOutputPath
            val duration = System.currentTimeMillis() - recordingStartMs
            
            if (!isClosed) {
                // ADD DELAY for emulator stability to release record surface
                cameraHandler.postDelayed({
                    if (!isClosed) startPreview()
                }, 300)
            }
            
            val file = File(path)
            val size = if (file.exists()) file.length() else 0L
            return RecordingResult(path, duration, size)
        }
    }

    // ---- Frame processing ----

    private fun emitFrame(image: Image) {
        val cb = onFrame ?: return
        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val size = buffer.remaining().toLong()
            val copy = ByteBuffer.allocateDirect(buffer.remaining())
            copy.put(buffer)
            copy.rewind()

            cb(CameraFrame(
                pixels      = copy,
                size        = size,
                width       = image.width.toLong(),
                height      = image.height.toLong(),
                timestamp   = System.currentTimeMillis(),
                orientation = 0L,
                textureId   = textureId,
            ))
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraCameraSession: emitFrame error: ${e.message}")
        }
    }
}
