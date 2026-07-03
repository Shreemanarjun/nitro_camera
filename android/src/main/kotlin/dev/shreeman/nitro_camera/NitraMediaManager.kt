package dev.shreeman.nitro_camera

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.TotalCaptureResult
import android.media.ExifInterface
import android.media.ImageReader
import android.media.MediaActionSound
import android.media.MediaCodec
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.util.Log
import android.view.Surface
import kotlinx.coroutines.*
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

    // Shutter sound — loaded once, released in release().
    private var shutterSound: MediaActionSound? = null

    fun playShutterSound() {
        try {
            val sound = shutterSound ?: MediaActionSound().also {
                it.load(MediaActionSound.SHUTTER_CLICK)
                shutterSound = it
            }
            sound.play(MediaActionSound.SHUTTER_CLICK)
        } catch (e: Exception) {
            Log.w("NitroCamera", "playShutterSound failed: ${e.message}")
        }
    }

    suspend fun takePhotoWithRequest(
        session: CameraCaptureSession,
        request: CaptureRequest,
        renderer: NitraRenderer,
        shader: String? = null,
        options: PhotoOptions? = null,
        onComplete: (() -> Unit)? = null
    ): PhotoResult = suspendCancellableCoroutine { cont ->
        Log.d("NitroCamera", "NitraMediaManager: capturing photo with request...")
        photoReader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireNextImage() ?: run {
                if (cont.isActive) cont.resumeWith(Result.failure(Exception("No image acquired")))
                return@setOnImageAvailableListener
            }
            
            // 1. Extract buffer and close Image IMMEDIATELY to free up hardware memory
            val buffer: ByteBuffer = image.planes[0].buffer
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            val imgWidth = image.width.toLong()
            val imgHeight = image.height.toLong()
            image.close()
            
            // 2. Offload HEAVY IO to a background thread to keep cameraHandler responsive
            // 2. Offload HEAVY IO and signal resumption
            val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
            scope.launch {
                try {
                    // RESUME preview as soon as pixels are acquired
                    onComplete?.invoke()

                    // Apply filter if specified
                    val filteredBytes = if (!shader.isNullOrEmpty()) {
                        renderer.applyFilterToStill(bytes, shader)
                    } else {
                        bytes
                    }

                    val tmp = File(context.cacheDir, "cap_${System.currentTimeMillis()}.jpg")
                    FileOutputStream(tmp).use { it.write(filteredBytes) }

                    // GPS EXIF tags from PhotoOptions (skipped when skipMetadata=1).
                    if (options != null && options.skipMetadata == 0L && options.hasLocation == 1L) {
                        writeExifGps(tmp, options)
                    }

                    if (cont.isActive) {
                        val sensorOrient =
                            (characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0).toLong()
                        val isFront = characteristics.get(CameraCharacteristics.LENS_FACING) ==
                            CameraCharacteristics.LENS_FACING_FRONT
                        cont.resumeWith(Result.success(PhotoResult(
                            path        = tmp.absolutePath,
                            width       = imgWidth,
                            height      = imgHeight,
                            fileSize    = tmp.length(),
                            orientation = sensorOrient,
                            isMirrored  = if (isFront) 1L else 0L,
                            timestamp   = System.currentTimeMillis(),
                        )))
                    }
                } catch (e: Exception) {
                    onComplete?.invoke()
                    if (cont.isActive) cont.resumeWith(Result.failure(e))
                }
            }
        }, cameraHandler)

        // The capture request callback is now only used for logging/error tracking.
        // Resumption is now signaled by the ImageAvailableListener below.
        if (options?.enableShutterSound == 1L) playShutterSound()
        try {
            session.capture(request, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureFailed(session: CameraCaptureSession, r: CaptureRequest, f: CaptureFailure) {
                    Log.e("NitroCamera", "Capture failed: ${f.reason}")
                    onComplete?.invoke() // Fail-safe resumption
                    if (cont.isActive) cont.resumeWith(Result.failure(Exception("Capture failed")))
                }
            }, cameraHandler)
        } catch (e: Exception) {
            onComplete?.invoke()
            if (cont.isActive) cont.resumeWith(Result.failure(e))
        }
    }

    /** Writes GPS EXIF tags into an already-written JPEG file. */
    private fun writeExifGps(file: File, options: PhotoOptions) {
        try {
            val exif = ExifInterface(file.absolutePath)
            exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE, toGpsDms(Math.abs(options.latitude)))
            exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, if (options.latitude >= 0) "N" else "S")
            exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE, toGpsDms(Math.abs(options.longitude)))
            exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, if (options.longitude >= 0) "E" else "W")
            exif.setAttribute(ExifInterface.TAG_GPS_ALTITUDE,
                "${Math.round(Math.abs(options.altitude) * 1000)}/1000")
            exif.setAttribute(ExifInterface.TAG_GPS_ALTITUDE_REF, if (options.altitude >= 0) "0" else "1")
            exif.saveAttributes()
        } catch (e: Exception) {
            // A metadata failure must not fail the capture — the JPEG is valid.
            Log.w("NitroCamera", "EXIF GPS write failed: ${e.message}")
        }
    }

    /** Decimal degrees → EXIF DMS rational string ("deg/1,min/1,sec*10000/10000"). */
    private fun toGpsDms(value: Double): String {
        var remainder = value
        val degrees = remainder.toInt(); remainder = (remainder - degrees) * 60.0
        val minutes = remainder.toInt(); remainder = (remainder - minutes) * 60.0
        val seconds = Math.round(remainder * 10000.0)
        return "$degrees/1,$minutes/1,$seconds/10000"
    }

    /// Invoked when MediaRecorder hits a configured maxDuration/maxFileSize limit.
    var onMaxReached: (() -> Unit)? = null

    // --- Persistent recorder surface (instant recording start) -----------------
    // One MediaCodec persistent input surface is created lazily and reused across
    // recordings. A fresh persistent surface has no defined buffer size, which
    // Camera2 needs when the surface is part of the capture session — so it is
    // "pre-wired" by a dormant, prepared (never started) MediaRecorder whose
    // encoder configures the surface to the recording size. The dormant recorder
    // is swapped for the real one at record time on the SAME surface, which is
    // the whole point of persistent surfaces: no session reconfiguration needed.
    private var persistentSurface: Surface? = null
    private var dormantRecorder: MediaRecorder? = null
    var isUsingPersistentSurface = false
        private set

    /** The pre-wired surface, or null when the persistent path is unavailable. */
    val persistentRecorderSurfaceOrNull: Surface?
        get() = persistentSurface?.takeIf { it.isValid }

    /**
     * Returns the persistent recorder surface ready for inclusion in a capture
     * session (creating + pre-wiring it on first use), or null when the device
     * rejects it — callers must then fall back to the GL recording pipeline.
     */
    fun acquirePersistentRecorderSurface(): Surface? {
        return try {
            val surface = persistentSurface?.takeIf { it.isValid }
                ?: MediaCodec.createPersistentInputSurface().also { persistentSurface = it }
            if (dormantRecorder == null && !(isRecording && isUsingPersistentSurface)) {
                dormantRecorder = createDormantRecorder(surface)
            }
            surface
        } catch (e: Exception) {
            Log.w("NitroCamera", "Persistent recorder surface unavailable: ${e.message}")
            releasePersistentSurface()
            null
        }
    }

    /**
     * A prepared-but-never-started video-only recorder that pins the persistent
     * surface's buffer-queue configuration while no real recording is active.
     */
    private fun createDormantRecorder(surface: Surface): MediaRecorder {
        val recorder = newRecorder()
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        val size = chooseRecordingSize()
        recorder.setVideoSize(size.width, size.height)
        recorder.setVideoEncodingBitRate(6_000_000)
        recorder.setVideoFrameRate(30)
        recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        recorder.setOutputFile(File(context.cacheDir, "nitra_recorder_warmup.mp4").absolutePath)
        recorder.setInputSurface(surface)
        try {
            recorder.prepare()
        } catch (e: Exception) {
            recorder.release()
            throw e
        }
        return recorder
    }

    /** Re-arms the dormant warm-up recorder after a persistent-surface recording ends. */
    fun rearmPersistentSurface() {
        val surface = persistentSurface?.takeIf { it.isValid } ?: return
        if (isRecording || dormantRecorder != null) return
        try {
            dormantRecorder = createDormantRecorder(surface)
        } catch (e: Exception) {
            Log.w("NitroCamera", "rearmPersistentSurface failed: ${e.message}")
        }
    }

    private fun releasePersistentSurface() {
        try { dormantRecorder?.release() } catch (_: Exception) {}
        dormantRecorder = null
        try { persistentSurface?.release() } catch (_: Exception) {}
        persistentSurface = null
    }

    private fun newRecorder(): MediaRecorder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }

    /**
     * Picks an ENCODER-SUPPORTED recording size, CAPPED at 1080p. Recording at
     * multi-MP dimensions makes both start (encoder alloc) and, especially,
     * stop() (moov finalise) slow — and arbitrary screen-derived sizes are the
     * main cause of `MediaRecorder.prepare()` failing with -2147483648.
     * Deterministic per device, so the dormant and real recorders always agree
     * (a size change on an in-session persistent surface would be invalid).
     */
    private fun chooseRecordingSize(): android.util.Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val supported = map?.getOutputSizes(MediaRecorder::class.java)
        val maxRecordDim = 1920
        val target = supported
            ?.filter { Math.max(it.width, it.height) <= maxRecordDim }
            ?.maxByOrNull { it.width.toLong() * it.height } // largest ≤1080p
            ?: supported?.minByOrNull {
                Math.abs(it.width.toLong() * it.height - width.toLong() * height)
            }
            ?: android.util.Size(width, height)
        // H.264 requires even dimensions on many devices.
        val safeWidth = if (target.width % 2 == 0) target.width else target.width - 1
        val safeHeight = if (target.height % 2 == 0) target.height else target.height - 1
        return android.util.Size(safeWidth, safeHeight)
    }

    fun prepareVideoRecorder(
        outputPath: String,
        codec: Int = 0,            // 0 = H.264, 1 = HEVC
        bitRate: Int = 0,          // 0 = default (6 Mbps)
        maxDurationMs: Int = 0,    // 0 = unlimited
        maxFileSizeBytes: Long = 0, // 0 = unlimited
        lat: Double = 0.0,
        lon: Double = 0.0,
        hasLocation: Boolean = false,
        inputSurface: Surface? = null, // persistent surface (instant start) or null → recorder-owned surface
    ): Surface {
        // A persistent-surface recording takes the surface over from the dormant
        // warm-up recorder.
        if (inputSurface != null && inputSurface === persistentSurface) {
            try { dormantRecorder?.release() } catch (_: Exception) {}
            dormantRecorder = null
        }

        val recorder = newRecorder()

        if (enableAudio) recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        // Android's MediaRecorder container is MPEG-4 for both mp4 & mov requests.
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)

        val size = chooseRecordingSize()
        recorder.setVideoSize(size.width, size.height)
        recorder.setVideoEncodingBitRate(if (bitRate > 0) bitRate else 6_000_000)
        recorder.setVideoFrameRate(30)

        val encoder = if (codec == 1 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            MediaRecorder.VideoEncoder.HEVC
        } else {
            MediaRecorder.VideoEncoder.H264
        }
        recorder.setVideoEncoder(encoder)
        if (enableAudio) recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)

        if (maxDurationMs > 0) recorder.setMaxDuration(maxDurationMs)
        if (maxFileSizeBytes > 0) recorder.setMaxFileSize(maxFileSizeBytes)
        if (hasLocation) recorder.setLocation(lat.toFloat(), lon.toFloat())
        if (maxDurationMs > 0 || maxFileSizeBytes > 0) {
            recorder.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED ||
                    what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED
                ) {
                    onMaxReached?.invoke()
                }
            }
        }

        recorder.setOutputFile(outputPath)
        if (inputSurface != null) recorder.setInputSurface(inputSurface)
        try {
            recorder.prepare()
        } catch (e: Exception) {
            recorder.release()
            throw e
        }

        mediaRecorder = recorder
        isUsingPersistentSurface = inputSurface != null
        recordingOutputPath = outputPath
        recordingStartMs = System.currentTimeMillis()
        isRecording = true
        // getSurface() throws when a persistent input surface is set.
        return inputSurface ?: recorder.surface
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
        val wasPersistent = isUsingPersistentSurface
        isUsingPersistentSurface = false

        if (wasPersistent) {
            // Re-arm the warm-up recorder OFF the critical stop path so the
            // persistent surface stays configured inside the live capture session
            // (and for any future session reconfiguration).
            cameraHandler.post { rearmPersistentSurface() }
        }

        val path = recordingOutputPath
        val duration = System.currentTimeMillis() - recordingStartMs
        val file = File(path)
        val size = if (file.exists()) file.length() else 0L

        return RecordingResult(path, duration, size)
    }

    fun release() {
        mediaRecorder?.release()
        mediaRecorder = null
        isRecording = false
        isUsingPersistentSurface = false
        releasePersistentSurface()
        try { shutterSound?.release() } catch (_: Exception) {}
        shutterSound = null
        photoReader.close()
    }
}
