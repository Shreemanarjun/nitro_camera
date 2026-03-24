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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// Alias to avoid conflict with Nitrogen-generated CameraDevice struct
import android.hardware.camera2.CameraDevice as AndroidCameraDevice

/**
 * Manages a single camera session for a specific texture.
 * Integrated with NitraRenderer for GPU-accelerated video filtering.
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

    // GPU Renderer for shaders and filters
    private val renderer = NitraRenderer(width, height)

    @Volatile
    private var isClosed = false
    private val stateLock = Any()

    // Active capture session
    private var captureSession: CameraCaptureSession? = null
    private var previewRequest: CaptureRequest? = null

    // Frame processing (CPU path)
    var frameProcessingEnabled = false
    var frameFormat = ImageFormat.YUV_420_888
    var onFrame: ((CameraFrame) -> Unit)? = null
    private var frameReader = ImageReader.newInstance(width, height, frameFormat, 2)

    // Camera characteristics
    private val characteristics: CameraCharacteristics by lazy {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        manager.getCameraCharacteristics(cameraDevice.id)
    }

    // Media Manager (Video/Photo logic extracted)
    private val mediaManager = NitraMediaManager(
        context, cameraDevice, characteristics, cameraHandler, width, height, enableAudio
    )

    private val isRecording get() = mediaManager.isRecording

    // ---- Lifecycle ----

    @SuppressLint("MissingPermission")
    fun startPreview() {
        synchronized(stateLock) {
            if (isClosed) return
            Log.d("NitroCamera", "NitraCameraSession: Starting preview (frameProcessing: $frameProcessingEnabled)")

            // We MUST ensure the renderer is set up on the GL thread (cameraHandler)
            // BEFORE we create the capture session, as we need its inputSurface.
            val setupComplete = java.util.concurrent.CountDownLatch(1)
            var setupError: Exception? = null

            cameraHandler.post {
                try {
                    renderer.setup(previewSurface)
                    setupComplete.countDown()
                } catch (e: Exception) {
                    setupError = e
                    setupComplete.countDown()
                }
            }

            // Blocking wait on current thread (Main or Open thread)
            // This is safe because it's orchestrated by openCamera (suspend) or similar.
            if (!setupComplete.await(5000, java.util.concurrent.TimeUnit.MILLISECONDS)) {
                throw Exception("Renderer setup timed out after 5s")
            }
            if (setupError != null) {
                throw setupError!!
            }

            val cameraStreamSurface = renderer.inputSurface!!
            val surfaces = mutableListOf<Surface>(cameraStreamSurface, mediaManager.photoReader.surface)
            if (frameProcessingEnabled) surfaces.add(frameReader.surface)

            try {
                cameraDevice.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        synchronized(stateLock) {
                            if (isClosed || mediaManager.isRecording) {
                                session.close()
                                return
                            }
                            Log.d("NitroCamera", "NitraCameraSession: Preview session configured")
                            captureSession = session
                            try {
                                val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_PREVIEW)
                                builder.addTarget(cameraStreamSurface)
                                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                                
                                // Set target FPS range
                                val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                                val bestRange = ranges?.firstOrNull { it.upper == fps && it.lower <= fps } 
                                             ?: ranges?.firstOrNull { it.upper >= fps }
                                if (bestRange != null) {
                                    builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, bestRange)
                                    Log.d("NitroCamera", "NitraCameraSession: Using FPS range $bestRange for target $fps")
                                }

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
        // Setup Frame processing listener
        setupFrameListener()
    }

    private fun setupFrameListener() {
        // 1. GPU Draw Trigger (Essential for preview filtering)
        renderer.inputSurfaceTexture?.setOnFrameAvailableListener({
            cameraHandler.post {
                if (!isClosed) {
                    try {
                        renderer.drawFrame()
                    } catch (e: Exception) {
                        Log.e("NitroCamera", "NitraCameraSession: GPU Draw error: ${e.message}")
                    }
                }
            }
        }, cameraHandler)

        // 2. CPU Frame Analysis (Optional)
        frameReader.setOnImageAvailableListener({ reader ->
            if (isClosed) return@setOnImageAvailableListener
            val image = try { reader.acquireLatestImage() } catch (e: Exception) { null } ?: return@setOnImageAvailableListener
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

            // CRITICAL: We must wait for the GL thread to release the renderer
            // BEFORE we release the surfaces on this thread.
            val releaseComplete = java.util.concurrent.CountDownLatch(1)
            cameraHandler.post {
                try {
                    renderer.release()
                    releaseComplete.countDown()
                } catch (e: Exception) {
                    Log.e("NitroCamera", "NitraCameraSession: EGL release failed: ${e.message}")
                    releaseComplete.countDown()
                }
            }

            try {
                releaseComplete.await(500, java.util.concurrent.TimeUnit.MILLISECONDS)
            } catch (e: Exception) {
                Log.e("NitroCamera", "NitraCameraSession: Timeout waiting for GL release")
            }

            previewSurface.release()
            surfaceTexture.release()
            mediaManager.release()
            frameReader.close()
            textureEntry.release()
            cameraThread.quitSafely()
        }
    }

    // ---- Frame / Filter controls ----

    fun setFrameFormat(format: Long) {
        synchronized(stateLock) {
            val newFormat = if (format == 0L) ImageFormat.YUV_420_888 else ImageFormat.PRIVATE
            if (newFormat == frameFormat) return

            frameFormat = newFormat
            frameReader.close()
            frameReader = ImageReader.newInstance(width, height, frameFormat, 2)
            setupFrameListener()

            // Re-config needed for format change
            if (!isClosed && !mediaManager.isRecording) startPreview()
        }
    }

    fun setFilterShader(shader: String) {
        cameraHandler.post {
            try {
                renderer.updateShader(shader)
            } catch (e: Exception) {
                Log.e("NitroCamera", "NitraCameraSession: Shader update failed: ${e.message}")
            }
        }
    }

    // ---- Camera controls ----

    fun setZoom(zoom: Double) {
        if (isClosed) return
        try {
            val session = captureSession ?: return
            val rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
            val builder = cameraDevice.createCaptureRequest(if (mediaManager.isRecording) AndroidCameraDevice.TEMPLATE_RECORD else AndroidCameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(renderer.inputSurface!!)
            if (mediaManager.isRecording) builder.addTarget(mediaManager.photoReader.surface /* placeholder */) // Handled by recorder

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
            builder.addTarget(renderer.inputSurface!!)

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
            builder.addTarget(renderer.inputSurface!!)
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
            builder.addTarget(renderer.inputSurface!!)
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
            builder.addTarget(renderer.inputSurface!!)
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
            builder.addTarget(renderer.inputSurface!!)
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
            builder.addTarget(renderer.inputSurface!!)
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
            builder.addTarget(renderer.inputSurface!!)
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

    // ---- Media Controls ----

    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun takePhoto(): PhotoResult = mediaManager.takePhoto(captureSession)

    fun startVideoRecording(outputPath: String) {
        synchronized(stateLock) {
            if (isClosed) return
            
            try {
                val recSurface = mediaManager.prepareVideoRecorder(outputPath)
                val cameraStreamSurface = renderer.inputSurface!!
                val surfaces = mutableListOf(cameraStreamSurface, recSurface, mediaManager.photoReader.surface)

                cameraDevice.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        synchronized(stateLock) {
                            if (isClosed) {
                                session.close()
                                return
                            }
                            captureSession = session
                            try {
                                val builder = cameraDevice.createCaptureRequest(AndroidCameraDevice.TEMPLATE_RECORD)
                                builder.addTarget(cameraStreamSurface)
                                builder.addTarget(recSurface)
                                session.setRepeatingRequest(builder.build(), null, cameraHandler)
                                mediaManager.startVideoRecorder()
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
                Log.e("NitroCamera", "NitraCameraSession: Failed to prepare recording: ${e.message}")
            }
        }
    }

    fun stopVideoRecording(): RecordingResult {
        val result = mediaManager.stopVideoRecording()
        if (!isClosed) {
            cameraHandler.postDelayed({ if (!isClosed) startPreview() }, 300)
        }
        return result
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
