package dev.shreeman.nitro_camera.outputs

import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.DngCreator
import android.hardware.camera2.TotalCaptureResult
import android.media.ExifInterface
import android.media.ImageReader
import android.media.MediaActionSound
import android.util.Log
import dev.shreeman.nitro_camera.extensions.isFrontFacing
import dev.shreeman.nitro_camera.extensions.sensorOrientationDegrees
import dev.shreeman.nitro_camera.session.CameraSession
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import nitro.nitro_camera_module.NitroCameraJniBridge
import nitro.nitro_camera_module.CameraEventType
import nitro.nitro_camera_module.InterruptionReason
import nitro.nitro_camera_module.PhotoOptions
import nitro.nitro_camera_module.PhotoResult
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.coroutines.resume

import android.hardware.camera2.CameraDevice as AndroidCameraDevice

/**
 * Owns still capture: the JPEG ImageReader, the AE precapture (flash) and
 * screen-fill flash sequences, the RAW/DNG path with its temporary session,
 * PhotoOptions handling (quality, red-eye, shutter sound, GPS EXIF) and the
 * shutter sound.
 *
 * vision-camera analogue: android/.../hybrids/outputs/HybridPhotoOutput.kt
 * (their ImageCapture-based photo output; the precapture sequence, DNG and
 * screen-flash paths here are Camera2 capabilities their CameraX engine
 * delegates to the framework).
 */
class PhotoOutput(private val session: CameraSession) {

    private companion object {
        /// Max wait for the AE precapture sequence to settle before capturing anyway.
        const val PRECAPTURE_TIMEOUT_MS = 1_500L

        /// Screen-fill flash (flash-less front cameras): time given to the white
        /// overlay + max-brightness window to actually light the subject (and AE
        /// to react) before the exposure starts.
        const val SCREEN_FLASH_ILLUMINATION_MS = 350L
    }

    // Photo capture (JPEG)
    val photoReader: ImageReader by lazy {
        val characteristics = session.characteristics
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.JPEG)?.sortedByDescending { it.width * it.height }
        val size = sizes?.firstOrNull() ?: android.util.Size(session.width, session.height)
        Log.d("NitroCamera", "PhotoOutput: PhotoReader initialized with ${size.width}x${size.height}")
        ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
    }

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

    suspend fun takePhoto(options: PhotoOptions? = null): PhotoResult {
        session.onEvent?.invoke(CameraEventType.PHOTOCAPTUREBEGAN, InterruptionReason.NONE, "")
        // The scene-mode HDR still request is what some HALs (e.g. Oplus at full
        // res) reject with REASON_ERROR — and a failed-then-retried capture is the
        // "slow photo". So DON'T use it on the primary request: the common path now
        // succeeds first try. A minimal request is still kept as a safety retry.
        return try {
            doCapture(useHdr = false, minimal = false, options = options)
        } catch (e: Exception) {
            Log.w("NitroCamera", "takePhoto failed (${e.message}); retrying minimal request")
            doCapture(useHdr = false, minimal = true, options = options)
        }
    }

    /**
     * Runs the standard Camera2 AE PRECAPTURE metering sequence on the live
     * repeating preview stream and waits (bounded, [PRECAPTURE_TIMEOUT_MS]) for
     * AE to settle. Without this, a still request carrying
     * AE_MODE_ON_ALWAYS_FLASH / ON_AUTO_FLASH captures its frame before the
     * flash is armed, so the flash never visibly fires on most HALs — that was
     * exactly the "flash doesn't fire on the back camera" bug (the old code set
     * TRIGGER_START on the still request itself, AFTER stopRepeating(), so the
     * sequence had no frames to run on). Never throws: on any failure or
     * timeout the still capture proceeds anyway.
     */
    private suspend fun runFlashPrecapture(captureSession: CameraCaptureSession) {
        val pSurface = session.previewSurface ?: return
        if (!pSurface.isValid) return
        val settled = CompletableDeferred<Unit>()
        // Camera2Basic-style two-phase wait:
        //   1) AE enters PRECAPTURE (or immediately reports FLASH_REQUIRED),
        //   2) AE leaves PRECAPTURE → CONVERGED / FLASH_REQUIRED (flash armed).
        var precaptureSeen = false
        val callback = object : CameraCaptureSession.CaptureCallback() {
            private fun handle(result: CaptureResult) {
                val ae = result.get(CaptureResult.CONTROL_AE_STATE)
                if (ae == null) { settled.complete(Unit); return } // LEGACY HAL: no AE state
                if (!precaptureSeen) {
                    when (ae) {
                        CaptureResult.CONTROL_AE_STATE_PRECAPTURE,
                        CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED -> precaptureSeen = true
                        // Some HALs skip the PRECAPTURE state entirely.
                        CaptureResult.CONTROL_AE_STATE_CONVERGED -> settled.complete(Unit)
                    }
                }
                if (precaptureSeen && ae != CaptureResult.CONTROL_AE_STATE_PRECAPTURE) {
                    settled.complete(Unit)
                }
            }
            override fun onCaptureProgressed(
                s: CameraCaptureSession, r: CaptureRequest, partial: CaptureResult,
            ) = handle(partial)
            override fun onCaptureCompleted(
                s: CameraCaptureSession, r: CaptureRequest, result: TotalCaptureResult,
            ) = handle(result)
        }
        try {
            // Watch AE states on the repeating preview stream… (fresh builder —
            // currentRequestBuilder is owned by the camera thread). Mirror the
            // normal repeating targets so neither a scanner/detector nor an
            // active persistent-surface recording stalls meanwhile.
            val recordSurface = session.recordingViaSessionSurface
            val repeating = session.cameraDevice.createCaptureRequest(
                if (recordSurface != null) AndroidCameraDevice.TEMPLATE_RECORD
                else AndroidCameraDevice.TEMPLATE_PREVIEW)
            repeating.addTarget(pSurface)
            if (recordSurface != null) repeating.addTarget(recordSurface)
            if (session.frameProcessingEnabled || session.nativeDetector.isNotEmpty()) {
                repeating.addTarget(session.frameOutput.surface)
            }
            session.applySessionSettings(repeating)
            captureSession.setRepeatingRequest(repeating.build(), callback, session.cameraHandler)

            // …and kick the metering sequence with a single triggered frame.
            val trigger = session.cameraDevice.createCaptureRequest(
                AndroidCameraDevice.TEMPLATE_PREVIEW)
            trigger.addTarget(pSurface)
            session.applySessionSettings(trigger)
            trigger.set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER,
                CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER_START)
            captureSession.capture(trigger.build(), callback, session.cameraHandler)

            val t0 = android.os.SystemClock.elapsedRealtime()
            val outcome = withTimeoutOrNull(PRECAPTURE_TIMEOUT_MS) { settled.await() }
            Log.i("NitroCamera", "Flash precapture " +
                (if (outcome != null) "settled" else "TIMED OUT (capturing anyway)") +
                " in ${android.os.SystemClock.elapsedRealtime() - t0}ms (flashMode=${session.flashMode})")
        } catch (e: Exception) {
            Log.w("NitroCamera", "Flash precapture failed (${e.message}); capturing anyway")
        }
    }

    /**
     * Screen-fill flash for flash-less (front) cameras: boosts the activity
     * window to max brightness so the Dart-side white overlay actually lights
     * the subject. Returns the previous screenBrightness override for
     * [restoreWindowBrightness]; null when no activity is attached.
     */
    private fun boostWindowBrightness(): Float? {
        val act = NitroCameraJniBridge.activity ?: run {
            Log.w("NitroCamera", "Screen-flash: no activity attached; skipping brightness boost")
            return null
        }
        return try {
            val previous = act.window.attributes.screenBrightness
            act.runOnUiThread {
                try {
                    val lp = act.window.attributes
                    lp.screenBrightness = 1.0f
                    act.window.attributes = lp
                } catch (e: Exception) {
                    Log.w("NitroCamera", "Screen-flash brightness boost failed: ${e.message}")
                }
            }
            Log.i("NitroCamera", "Screen-flash: window brightness boosted to 1.0 (was $previous)")
            previous
        } catch (e: Exception) {
            Log.w("NitroCamera", "Screen-flash brightness boost failed: ${e.message}")
            null
        }
    }

    /** Restores the pre-boost window brightness ([previous]; null → system default). */
    private fun restoreWindowBrightness(previous: Float?) {
        val act = NitroCameraJniBridge.activity ?: return
        act.runOnUiThread {
            try {
                val lp = act.window.attributes
                lp.screenBrightness = previous
                    ?: android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                act.window.attributes = lp
                Log.i("NitroCamera", "Screen-flash: window brightness restored to ${lp.screenBrightness}")
            } catch (_: Exception) {}
        }
    }

    private suspend fun doCapture(
        useHdr: Boolean,
        minimal: Boolean,
        options: PhotoOptions? = null,
    ): PhotoResult {
        val captureSession = session.captureSession ?: throw Exception("No active session")
        val characteristics = session.characteristics

        val wantsFlash = !minimal && !session.torchEnabled &&
            (session.flashMode == 1L || session.flashMode == 2L)

        // Flash-equipped camera (back): run the AE PRECAPTURE sequence on the
        // LIVE repeating stream BEFORE stopping it — this is what actually arms
        // the flash for the still (both flash=on and flash=auto need it).
        if (wantsFlash && session.hasFlashUnit) {
            runFlashPrecapture(captureSession)
        }

        // Flash-less camera (front): "flash" = screen fill. Emit the shutter
        // event EARLY so the app's white FlashOverlay is up during exposure,
        // boost the window to max brightness, and give the display + AE a
        // moment to light the subject. Brightness restored in the finally.
        val screenFlash = wantsFlash && !session.hasFlashUnit
        var previousBrightness: Float? = null
        if (screenFlash) {
            Log.i("NitroCamera", "Screen-flash capture: flashMode=${session.flashMode} (no flash unit)")
            session.onEvent?.invoke(CameraEventType.PHOTOCAPTURESHUTTER, InterruptionReason.NONE, "")
            previousBrightness = boostWindowBrightness()
            delay(SCREEN_FLASH_ILLUMINATION_MS)
        }

        try {
            // Stop the preview repeating request to prepare for the still capture.
            try { captureSession.stopRepeating() } catch (_: Exception) {}

            val builder = session.cameraDevice.createCaptureRequest(
                AndroidCameraDevice.TEMPLATE_STILL_CAPTURE)
            builder.addTarget(photoReader.surface)

            val orientation = characteristics.sensorOrientationDegrees(0)
            builder.set(CaptureRequest.JPEG_ORIENTATION, orientation)

            // PhotoOptions.qualityPrioritization → JPEG compression level
            // (0 = speed, 1 = balanced, 2 = quality).
            if (options != null) {
                val quality: Byte = when (options.qualityPrioritization) {
                    0L -> 85
                    2L -> 100
                    else -> 92
                }
                builder.set(CaptureRequest.JPEG_QUALITY, quality)
            }

            if (minimal) {
                builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            } else {
                // Sets AE_MODE_ON_ALWAYS_FLASH (on) / ON_AUTO_FLASH (auto) — with
                // STILL_CAPTURE intent + the completed precapture above, the HAL
                // fires the flash for this frame. (No TRIGGER_START here: the old
                // trigger-on-the-still bug captured the frame before the flash.)
                session.applySessionSettings(builder)
                // HDR still (scene mode) when requested + supported.
                if (useHdr) {
                    val sceneModes = characteristics.get(
                        CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES) ?: intArrayOf()
                    if (sceneModes.contains(CaptureRequest.CONTROL_SCENE_MODE_HDR)) {
                        builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_USE_SCENE_MODE)
                        builder.set(CaptureRequest.CONTROL_SCENE_MODE, CaptureRequest.CONTROL_SCENE_MODE_HDR)
                    }
                }
                // Auto red-eye reduction — only meaningful with auto-flash on a
                // flash-equipped camera advertising the REDEYE AE mode.
                if (options?.enableAutoRedEyeReduction == 1L && session.flashMode == 2L && session.hasFlashUnit) {
                    val aeModes = characteristics.get(
                        CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES) ?: intArrayOf()
                    if (aeModes.contains(CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH_REDEYE)) {
                        builder.set(CaptureRequest.CONTROL_AE_MODE,
                            CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH_REDEYE)
                        builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
                    }
                }
            }

            // The shutter moment (drives the app's shutter-flash animation).
            // The screen-flash path already emitted it before the illumination delay.
            if (!screenFlash) {
                session.onEvent?.invoke(CameraEventType.PHOTOCAPTURESHUTTER, InterruptionReason.NONE, "")
            }

            return takePhotoWithRequest(
                captureSession = captureSession,
                request = builder.build(),
                options = options,
            ) {
                // Resume the preview repeating request after capture.
                session.cameraHandler.post { session.triggerUpdate() }
            }
        } finally {
            if (screenFlash) restoreWindowBrightness(previousBrightness)
        }
    }

    /**
     * RAW (DNG) still capture — PhotoOptions.outputFormat == 1.
     *
     * RAW_SENSOR can't be piggybacked onto the normal preview/JPEG/YUV stream
     * combination on most devices, so this reconfigures a TEMPORARY capture
     * session over [preview, RAW], captures one frame together with its
     * TotalCaptureResult, writes the DNG via DngCreator, and restores the normal
     * preview session (the existing startPreview() configuration path) in a
     * finally block. Acceptable for stills; the preview freezes briefly.
     */
    suspend fun takeDngPhoto(options: PhotoOptions): PhotoResult {
        if (session.isClosed) throw IllegalStateException("Camera session is closed")
        if (session.videoOutput.isRecording) {
            throw IllegalStateException("Cannot capture DNG while recording video")
        }
        val characteristics = session.characteristics
        val caps = characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
            ?: intArrayOf()
        if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW)) {
            throw IllegalStateException("RAW capture not supported by this camera")
        }

        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val rawSize = map?.getOutputSizes(ImageFormat.RAW_SENSOR)
            ?.maxByOrNull { it.width.toLong() * it.height }
            ?: characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)?.let {
                android.util.Size(it.width, it.height)
            }
            ?: throw IllegalStateException("No RAW_SENSOR output size available")

        val pSurface = session.previewSurface
            ?: throw IllegalStateException("Preview surface not ready for RAW capture")

        val rawReader = ImageReader.newInstance(
            rawSize.width, rawSize.height, ImageFormat.RAW_SENSOR, 2)
        var rawSession: CameraCaptureSession? = null

        // Tear down the normal session — it is restored in the finally block.
        try { session.captureSession?.stopRepeating() } catch (_: Exception) {}
        try { session.captureSession?.close() } catch (_: Exception) {}
        session.captureSession = null

        try {
            rawSession = suspendCancellableCoroutine<CameraCaptureSession> { cont ->
                try {
                    session.cameraDevice.createCaptureSession(
                        listOf(pSurface, rawReader.surface),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                if (cont.isActive) cont.resume(session)
                            }
                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                session.close()
                                if (cont.isActive) cont.resumeWith(Result.failure(
                                    IllegalStateException("RAW capture session configuration failed")))
                            }
                        },
                        session.cameraHandler,
                    )
                } catch (e: Exception) {
                    if (cont.isActive) cont.resumeWith(Result.failure(e))
                }
            }

            val imageDeferred = CompletableDeferred<android.media.Image>()
            val resultDeferred = CompletableDeferred<TotalCaptureResult>()
            rawReader.setOnImageAvailableListener({ reader ->
                val img = try {
                    reader.acquireNextImage()
                } catch (e: Exception) {
                    imageDeferred.completeExceptionally(e)
                    null
                }
                if (img != null && !imageDeferred.complete(img)) img.close()
            }, session.cameraHandler)

            val builder = session.cameraDevice.createCaptureRequest(
                AndroidCameraDevice.TEMPLATE_STILL_CAPTURE)
            builder.addTarget(rawReader.surface)
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)

            if (options.enableShutterSound == 1L) playShutterSound()

            rawSession.capture(builder.build(), object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) { resultDeferred.complete(result) }

                override fun onCaptureFailed(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    val e = IllegalStateException("RAW capture failed (reason ${failure.reason})")
                    resultDeferred.completeExceptionally(e)
                    imageDeferred.completeExceptionally(e)
                }
            }, session.cameraHandler)

            val image = withTimeout(10_000) { imageDeferred.await() }
            val totalResult = try {
                withTimeout(10_000) { resultDeferred.await() }
            } catch (e: Exception) {
                image.close()
                throw e
            }

            val sensorOrientation = characteristics.sensorOrientationDegrees(0)
            val isFront = characteristics.isFrontFacing

            val file = withContext(Dispatchers.IO) {
                val dng = DngCreator(characteristics, totalResult)
                try {
                    dng.setOrientation(when (sensorOrientation) {
                        90 -> android.media.ExifInterface.ORIENTATION_ROTATE_90
                        180 -> android.media.ExifInterface.ORIENTATION_ROTATE_180
                        270 -> android.media.ExifInterface.ORIENTATION_ROTATE_270
                        else -> android.media.ExifInterface.ORIENTATION_NORMAL
                    })
                    if (options.hasLocation == 1L && options.skipMetadata == 0L) {
                        dng.setLocation(android.location.Location("nitro_camera").apply {
                            latitude = options.latitude
                            longitude = options.longitude
                            altitude = options.altitude
                        })
                    }
                    val out = File(session.context.cacheDir, "cap_${System.currentTimeMillis()}.dng")
                    FileOutputStream(out).use { dng.writeImage(it, image) }
                    out
                } finally {
                    try { dng.close() } catch (_: Exception) {}
                    try { image.close() } catch (_: Exception) {}
                }
            }

            return PhotoResult(
                path        = file.absolutePath,
                width       = rawSize.width.toLong(),
                height      = rawSize.height.toLong(),
                fileSize    = file.length(),
                orientation = sensorOrientation.toLong(),
                isMirrored  = if (isFront) 1L else 0L,
                timestamp   = System.currentTimeMillis(),
            )
        } catch (e: Exception) {
            throw IllegalStateException("DNG capture failed: ${e.message}", e)
        } finally {
            try { rawSession?.close() } catch (_: Exception) {}
            try { rawReader.close() } catch (_: Exception) {}
            // Restore the normal preview session via the existing config path.
            if (!session.isClosed) session.startPreview()
        }
    }

    private suspend fun takePhotoWithRequest(
        captureSession: CameraCaptureSession,
        request: CaptureRequest,
        options: PhotoOptions? = null,
        onComplete: (() -> Unit)? = null,
    ): PhotoResult = suspendCancellableCoroutine { cont ->
        Log.d("NitroCamera", "PhotoOutput: capturing photo with request...")
        val characteristics = session.characteristics
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
                    val shader = session.lastRawShader
                    val filteredBytes = if (shader.isNotEmpty()) {
                        session.renderer.applyFilterToStill(bytes, shader)
                    } else {
                        bytes
                    }

                    val tmp = File(session.context.cacheDir, "cap_${System.currentTimeMillis()}.jpg")
                    FileOutputStream(tmp).use { it.write(filteredBytes) }

                    // The GL filter pass decodes + re-encodes the JPEG (NitraRenderer
                    // .applyFilterToStill), which DROPS the EXIF orientation the camera
                    // wrote via JPEG_ORIENTATION. The raw pixels are in sensor
                    // orientation and rely on that tag, so a filtered still would save
                    // rotated. Re-attach the source orientation so a filtered photo
                    // orients exactly like an unfiltered one. (vision-camera never hits
                    // this: CameraX bakes orientation into the JPEG and does no GL still
                    // post-processing.)
                    if (shader.isNotEmpty()) {
                        val srcOrientation = ExifInterface(java.io.ByteArrayInputStream(bytes))
                            .getAttribute(ExifInterface.TAG_ORIENTATION)
                        if (srcOrientation != null) {
                            ExifInterface(tmp.absolutePath).apply {
                                setAttribute(ExifInterface.TAG_ORIENTATION, srcOrientation)
                                saveAttributes()
                            }
                        }
                    }

                    // GPS EXIF tags from PhotoOptions (skipped when skipMetadata=1).
                    if (options != null && options.skipMetadata == 0L && options.hasLocation == 1L) {
                        writeExifGps(tmp, options)
                    }

                    if (cont.isActive) {
                        val sensorOrient = characteristics.sensorOrientationDegrees(0).toLong()
                        val isFront = characteristics.isFrontFacing
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
        }, session.cameraHandler)

        // The capture request callback is now only used for logging/error tracking.
        // Resumption is now signaled by the ImageAvailableListener below.
        if (options?.enableShutterSound == 1L) playShutterSound()
        try {
            captureSession.capture(request, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession, r: CaptureRequest, result: TotalCaptureResult,
                ) {
                    // Evidence trail for flash debugging: FLASH_STATE_FIRED proves
                    // the unit actually fired for this still.
                    val flashState = when (result.get(CaptureResult.FLASH_STATE)) {
                        CaptureResult.FLASH_STATE_FIRED -> "FIRED"
                        CaptureResult.FLASH_STATE_PARTIAL -> "PARTIAL"
                        CaptureResult.FLASH_STATE_READY -> "READY"
                        CaptureResult.FLASH_STATE_CHARGING -> "CHARGING"
                        CaptureResult.FLASH_STATE_UNAVAILABLE -> "UNAVAILABLE"
                        else -> "?"
                    }
                    val aeState = result.get(CaptureResult.CONTROL_AE_STATE)
                    Log.i("NitroCamera",
                        "Still capture completed: flashState=$flashState aeState=$aeState " +
                        "aeMode=${r.get(CaptureRequest.CONTROL_AE_MODE)} flashMode=${r.get(CaptureRequest.FLASH_MODE)}")
                }
                override fun onCaptureFailed(session: CameraCaptureSession, r: CaptureRequest, f: CaptureFailure) {
                    Log.e("NitroCamera", "Capture failed: ${f.reason}")
                    onComplete?.invoke() // Fail-safe resumption
                    if (cont.isActive) cont.resumeWith(Result.failure(Exception("Capture failed")))
                }
            }, session.cameraHandler)
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

    /** Releases the shutter sound + JPEG reader. */
    fun release() {
        try { shutterSound?.release() } catch (_: Exception) {}
        shutterSound = null
        photoReader.close()
    }
}
