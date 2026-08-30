package dev.shreeman.nitro_camera.session

import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.media.MediaRecorder
import android.util.Range
import android.util.Size
import dev.shreeman.nitro_camera.utils.RecordingOrientation

/**
 * Native-side format / FPS negotiation: picks the concrete stream sizes and AE
 * target FPS range for a session out of what the device actually advertises.
 *
 * vision-camera analogue: android/.../session/ConstraintResolver.kt (their
 * resolver negotiates CameraX use-case combos + FPS in two passes; ours
 * resolves the Camera2 stream sizes + FPS range directly, but it is the same
 * "constraints in → supported concrete config out" responsibility).
 */
object ConstraintResolver {

    /**
     * Preview (SurfaceTexture / PRIV) stream size: the advertised size that
     * matches the requested aspect ratio best, tie-broken by the closest area.
     * (The preview STRETCH is fixed on the Flutter side — the native GL
     * renderer already center-crops — so we keep this proven selection to
     * avoid breaking the device's supported stream combination.)
     */
    fun resolvePreviewSize(
        characteristics: CameraCharacteristics,
        width: Int,
        height: Int,
    ): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw IllegalStateException("No stream configuration map")
        // getOutputSizes() may return null (or an empty array) on some HALs —
        // UVC/external cameras especially. This runs in the CameraSession
        // constructor, so an unchecked access aborts every open on such devices.
        val sizes = map.getOutputSizes(SurfaceTexture::class.java)
        if (sizes == null || sizes.isEmpty()) return Size(width, height)

        val targetAspect = width.toFloat() / height.toFloat()

        return sizes.minByOrNull { s ->
            val aspect = s.width.toFloat() / s.height.toFloat()
            val aspectDiff = Math.abs(aspect - targetAspect)
            val areaDiff = Math.abs(s.width * s.height - width * height)
            aspectDiff * 1000000 + areaDiff
        } ?: sizes[0]
    }

    /**
     * Picks the AE target FPS range for the preview request — the EXACT
     * vision-camera v5 `ConstraintResolver` pass-2 algorithm: minimise
     * `abs(upper − target)`, tie-break by the higher lower bound (a tighter
     * range holds the frame rate steadier than one the AE can drop to 7fps
     * in low light). No target (`requestedFps <= 0`) keeps the old
     * highest-upper behaviour (Dart's "platform decides" default).
     */
    fun resolveFpsRange(
        characteristics: CameraCharacteristics,
        requestedFps: Int,
    ): Range<Int>? {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?: return null
        if (requestedFps <= 0) return ranges.maxByOrNull { it.upper }
        return ranges.minWithOrNull(
            compareBy<Range<Int>> { Math.abs(it.upper - requestedFps) }
                .thenByDescending { it.lower }
        )
    }

    /**
     * Frame-processing (scanner) YUV stream size — MUST be a size the camera
     * actually advertises for YUV_420_888, otherwise the HAL may accept the
     * session and then never deliver a single buffer. Prefers the requested
     * size when supported, else the closest supported size by area.
     */
    fun resolveFrameReaderSize(
        characteristics: CameraCharacteristics,
        width: Int,
        height: Int,
    ): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val yuvSizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
        return when {
            yuvSizes == null || yuvSizes.isEmpty() -> Size(width, height)
            yuvSizes.any { it.width == width && it.height == height } ->
                Size(width, height)
            else -> yuvSizes.minByOrNull {
                Math.abs(it.width.toLong() * it.height - width.toLong() * height)
            }!!
        }
    }

    /**
     * Picks an ENCODER-SUPPORTED recording size, CAPPED at 1080p. Recording at
     * multi-MP dimensions makes both start (encoder alloc) and, especially,
     * stop() (moov finalise) slow — and arbitrary screen-derived sizes are the
     * main cause of `MediaRecorder.prepare()` failing with -2147483648.
     * Deterministic per device, so the dormant and real recorders always agree
     * (a size change on an in-session persistent surface would be invalid).
     */
    fun resolveRecordingSize(
        characteristics: CameraCharacteristics,
        width: Int,
        height: Int,
        portrait: Boolean = false,
    ): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val supported = map?.getOutputSizes(MediaRecorder::class.java)
        val maxRecordDim = 1920
        // Pick the encoder size matching the SESSION aspect ratio (16:9 for a
        // 1920×1080 request), not the largest by area — that grabbed a 4:3 size
        // for a 16:9 session and stretched the recording (the squish bug).
        val targetAspect = Math.max(width, height).toFloat() / Math.max(1, Math.min(width, height))
        val pairs = supported?.map { it.width to it.height } ?: emptyList()
        val best = RecordingOrientation.bestEncoderSize(pairs, targetAspect, maxRecordDim)
            ?: (width to height)
        // Encoder output sizes are reported LANDSCAPE (long edge = width). The GL
        // pipeline draws already-upright content, so a portrait recording needs a
        // TALL surface; the persistent/raw-sensor path keeps landscape + a hint.
        val (w, h) = RecordingOrientation.orientSize(best.first, best.second, portrait)
        return Size(w, h)
    }
}
