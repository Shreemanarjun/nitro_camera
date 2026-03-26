package dev.shreeman.nitro_camera

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.util.Log
import android.view.Surface
import kotlinx.coroutines.suspendCancellableCoroutine
import nitro.nitro_camera_module.*
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer

// Alias to avoid conflict with Nitrogen-generated CameraDevice struct
import android.hardware.camera2.CameraDevice as AndroidCameraDevice

/**
 * Handles media capture (Photos and Videos) for a NitraCameraSession.
 */
class NitraMediaManager(
    private val context: Context,
    private val cameraDevice: AndroidCameraDevice,
    private val characteristics: CameraCharacteristics,
    private val cameraHandler: Handler,
    private val width: Int,
    private val height: Int,
    private val enableAudio: Boolean,
) {
    // Photo capture (JPEG)
    val photoReader: ImageReader by lazy {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.JPEG)?.sortedByDescending { it.width * it.height }
        val size = sizes?.firstOrNull() ?: android.util.Size(width, height)
        Log.d("NitroCamera", "NitraMediaManager: PhotoReader initialized with ${size.width}x${size.height}")
        ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
    }

    // Video recording state
    private var mediaRecorder: MediaRecorder? = null
    private var recordingStartMs = 0L
    var recordingOutputPath = ""
        private set
    var isRecording = false
        private set

    suspend fun takePhotoWithRequest(
        session: CameraCaptureSession,
        request: CaptureRequest,
        onComplete: (() -> Unit)? = null
    ): PhotoResult = suspendCancellableCoroutine { cont ->
        Log.d("NitroCamera", "NitraMediaManager: capturing photo with request...")
        photoReader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireNextImage() ?: run {
                if (cont.isActive) cont.resumeWith(Result.failure(Exception("No image acquired")))
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
                if (cont.isActive) {
                    cont.resumeWith(Result.success(PhotoResult(
                        path     = tmp.absolutePath,
                        width    = imgWidth,
                        height   = imgHeight,
                        fileSize = bytes.size.toLong()
                    )))
                }
            } catch (e: Exception) {
                image.close()
                if (cont.isActive) cont.resumeWith(Result.failure(e))
            } finally {
                reader.setOnImageAvailableListener(null, null)
            }
        }, cameraHandler)

        try {
            session.capture(request, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                    onComplete?.invoke()
                }
                override fun onCaptureFailed(session: CameraCaptureSession, request: CaptureRequest, failure: CaptureFailure) {
                    onComplete?.invoke()
                }
            }, cameraHandler)
        } catch (e: Exception) {
            if (cont.isActive) cont.resumeWith(Result.failure(e))
        }
    }

    fun prepareVideoRecorder(outputPath: String): Surface {
        recordingOutputPath = outputPath
        recordingStartMs = System.currentTimeMillis()
        isRecording = true

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
        return recorder.surface
    }

    fun startVideoRecorder() {
        mediaRecorder?.start()
    }

    fun pauseVideoRecording() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try { mediaRecorder?.pause() } catch (e: Exception) {
                Log.w("NitroCamera", "pauseVideoRecording: ${e.message}")
            }
        }
    }

    fun resumeVideoRecording() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try { mediaRecorder?.resume() } catch (e: Exception) {
                Log.w("NitroCamera", "resumeVideoRecording: ${e.message}")
            }
        }
    }

    fun stopVideoRecording(): RecordingResult {
        val recorder = mediaRecorder ?: return RecordingResult("", 0L, 0L)
        try {
            recorder.stop()
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraMediaManager: Error stopping recorder: ${e.message}")
        }
        recorder.release()
        mediaRecorder = null
        isRecording = false

        val path = recordingOutputPath
        val duration = System.currentTimeMillis() - recordingStartMs
        val file = File(path)
        val size = if (file.exists()) file.length() else 0L

        return RecordingResult(path, duration, size)
    }

    fun release() {
        mediaRecorder?.release()
        mediaRecorder = null
        photoReader.close()
    }
}
