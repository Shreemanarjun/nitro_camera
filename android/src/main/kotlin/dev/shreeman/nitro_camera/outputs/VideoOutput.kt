package dev.shreeman.nitro_camera.outputs

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.media.MediaCodec
import android.media.MediaMetadataRetriever
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.util.Log
import android.view.Surface
import dev.shreeman.nitro_camera.session.ConstraintResolver
import nitro.nitro_camera_module.RecordingResult
import java.io.File

/**
 * Owns the video recorder: the MediaRecorder lifecycle, the persistent
 * (pre-wireable) encoder input surface for instant recording starts, and the
 * maxDuration/maxFileSize limits.
 *
 * vision-camera analogue: android/.../hybrids/outputs/HybridVideoOutput.kt +
 * hybrids/recording/HybridVideoRecorder.kt (their Recorder/Recording pair;
 * ours is MediaRecorder-based with a dormant warm-up recorder pinning the
 * persistent surface — a Camera2-only capability their CameraX engine lacks).
 */
class VideoOutput(
    private val context: Context,
    private val characteristics: CameraCharacteristics,
    private val cameraHandler: Handler,
    private val width: Int,
    private val height: Int,
    private val enableAudio: Boolean,
) {
    // Video recording state
    private var mediaRecorder: MediaRecorder? = null
    private var recordingStartMs = 0L
    // Pause bookkeeping: MediaRecorder.pause() stops writing frames, so the
    // MEDIA duration excludes paused time — but a naive wall-clock
    // (now - startMs) would count it. Track the accumulated pause span and
    // subtract it so durationMs reflects recorded media (matching iOS, which
    // shifts sample timestamps by its totalPauseOffset).
    private var pausedAccumulatedMs = 0L
    private var pauseStartMs = 0L
    private var recordingWidth = 0
    private var recordingHeight = 0
    private var recordingCodec = 0L
    private var recordingFileType = 0L
    private var recordingFinishedReason = 0L
    var recordingOutputPath = ""
        private set
    var isRecording = false
        private set

    /// Invoked when MediaRecorder hits a configured maxDuration/maxFileSize limit.
    var onMaxReached: (() -> Unit)? = null

    /// Invoked on an async MediaRecorder error (encoder died, mediaserver
    /// crash). Args: (what, extra) from MediaRecorder.OnErrorListener.
    var onRecorderError: ((Int, Int) -> Unit)? = null

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
        val size = ConstraintResolver.resolveRecordingSize(characteristics, width, height)
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
     * [orientationHintDeg] — clockwise rotation a player must apply to the
     * stored frames (the MPEG-4 `tkhd` transform matrix). The caller owns the
     * value because it depends on the recording path: the persistent-surface
     * path muxes RAW sensor buffers and needs the full sensor-mount + device
     * rotation, while the GL pipeline has already rotated the pixels itself
     * and passes 0 so the clip is not rotated twice.
     */
    fun prepareVideoRecorder(
        outputPath: String,
        orientationHintDeg: Int,
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

        val size = ConstraintResolver.resolveRecordingSize(characteristics, width, height)
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

        // The muxer's `tkhd` transform matrix — for the persistent-surface path
        // the ONLY thing that tells a player which way is up, since the raw
        // sensor buffers reach the encoder unrotated. Must be set before
        // prepare().
        recorder.setOrientationHint(((orientationHintDeg % 360) + 360) % 360)

        if (maxDurationMs > 0) recorder.setMaxDuration(maxDurationMs)
        if (maxFileSizeBytes > 0) recorder.setMaxFileSize(maxFileSizeBytes)
        if (hasLocation) recorder.setLocation(lat.toFloat(), lon.toFloat())
        if (maxDurationMs > 0 || maxFileSizeBytes > 0) {
            recorder.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED ||
                    what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED
                ) {
                    recordingFinishedReason =
                        if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) 1L else 2L
                    onMaxReached?.invoke()
                }
            }
        }
        // Without a listener, an async recorder error (encoder death,
        // mediaserver crash) is completely invisible: isRecording stays true
        // and a later stop() blesses a corrupt file. Mark the recording failed
        // and let the session auto-stop it.
        recorder.setOnErrorListener { _, what, extra ->
            Log.e("NitroCamera", "VideoOutput: MediaRecorder error what=$what extra=$extra")
            recordingFinishedReason = 3L
            onRecorderError?.invoke(what, extra)
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
        recordingWidth = size.width
        recordingHeight = size.height
        recordingCodec = if (encoder == MediaRecorder.VideoEncoder.HEVC) 1L else 0L
        recordingFileType = 0L // MediaRecorder writes MPEG-4; .mov requests map to mp4 on Android.
        recordingFinishedReason = 0L
        recordingStartMs = System.currentTimeMillis()
        pausedAccumulatedMs = 0L
        pauseStartMs = 0L
        isRecording = true
        // getSurface() throws when a persistent input surface is set.
        return inputSurface ?: recorder.surface
    }

    fun startVideoRecorder() {
        mediaRecorder?.start()
    }

    fun pauseVideoRecording() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                mediaRecorder?.pause()
                // Open a pause span (ignore a redundant pause while paused).
                if (pauseStartMs == 0L) pauseStartMs = System.currentTimeMillis()
            } catch (e: Exception) {
                Log.w("NitroCamera", "pauseVideoRecording: ${e.message}")
            }
        }
    }

    fun resumeVideoRecording() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                mediaRecorder?.resume()
                // Close the pause span, folding it into the accumulated total.
                if (pauseStartMs > 0L) {
                    pausedAccumulatedMs += System.currentTimeMillis() - pauseStartMs
                    pauseStartMs = 0L
                }
            } catch (e: Exception) {
                Log.w("NitroCamera", "resumeVideoRecording: ${e.message}")
            }
        }
    }

    fun stopVideoRecording(): RecordingResult {
        val recorder = mediaRecorder ?: return RecordingResult("", 0L, 0L, 0L, 0L, 0L, 0L, 0L)
        // stop() throwing (classically RuntimeException/-1007 when zero frames
        // reached the encoder) means the MP4 moov atom was never written — the
        // file on disk is truncated and unplayable. Delete it and report the
        // failure instead of returning a corrupt file as a successful recording.
        var stopFailed = false
        // Sample the stop instant BEFORE recorder.stop(): the recorded media
        // ends when stop is requested, but stop() itself blocks for the encoder
        // flush + moov finalise (100-300 ms on hardware, seconds on the
        // emulator's software encoder). Sampling afterwards leaked that
        // latency into durationMs — a 2 s clip reported 4.7 s.
        val stopRequestedMs = System.currentTimeMillis()
        try {
            recorder.stop()
        } catch (e: Exception) {
            Log.e("NitroCamera", "VideoOutput: Error stopping recorder: ${e.message}")
            stopFailed = true
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
        // Stopped while paused: close the open span first, then exclude ALL
        // paused time so the wall-clock estimate is the recorded-media length.
        if (pauseStartMs > 0L) {
            pausedAccumulatedMs += stopRequestedMs - pauseStartMs
            pauseStartMs = 0L
        }
        val wallDuration = (stopRequestedMs - recordingStartMs - pausedAccumulatedMs).coerceAtLeast(0L)
        val file = File(path)

        // recordingFinishedReason == 3L: the async error listener fired — the
        // stream is compromised even if stop() happened not to throw.
        if (stopFailed || recordingFinishedReason == 3L) {
            if (file.exists()) file.delete()
            // finishedReason 3 = failed (see Dart RecordingFinishedReason).
            return RecordingResult("", 0L, 0L, 0L, 0L, 0L, 0L, 3L)
        }
        val size = if (file.exists()) file.length() else 0L
        // Prefer the container's own duration (what a player will report;
        // MediaRecorder.pause() stops writing, so paused spans are already
        // excluded) — the wall clock is the fallback for an unparsable file.
        val duration = mediaDurationMs(file) ?: wallDuration

        return RecordingResult(
            path,
            duration,
            size,
            recordingWidth.toLong(),
            recordingHeight.toLong(),
            recordingCodec,
            recordingFileType,
            recordingFinishedReason,
        )
    }

    /** Duration from the finalised container's metadata, or null if unreadable. */
    private fun mediaDurationMs(file: File): Long? {
        if (!file.exists() || file.length() == 0L) return null
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(file.absolutePath)
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.takeIf { it > 0L }
        } catch (e: Exception) {
            Log.w("NitroCamera", "VideoOutput: could not read media duration: ${e.message}")
            null
        } finally {
            try { mmr.release() } catch (_: Exception) {}
        }
    }

    fun release() {
        mediaRecorder?.release()
        mediaRecorder = null
        isRecording = false
        isUsingPersistentSurface = false
        releasePersistentSurface()
    }
}
