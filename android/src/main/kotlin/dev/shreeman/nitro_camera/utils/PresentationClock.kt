package dev.shreeman.nitro_camera.utils

/** Encoder presentation times: monotonic clock, strictly increasing per surface. */
object PresentationClock {
    /**
     * [sensorNs] on the monotonic clock MediaRecorder / MediaCodec use for
     * pause/resume. Camera2 stamps REALTIME (elapsedRealtime, counts deep
     * sleep) on most devices; the camera service converts that only for
     * surfaces it hands straight to an encoder, not for our GL path, so a
     * paused-and-resumed GL recording grew by the whole sleep time (a 6 s clip
     * reported as an hour). Picks whichever clock [sensorNs] is closer to, so
     * monotonic-stamped cameras pass through unchanged.
     */
    fun toMonotonic(sensorNs: Long, realtimeNowNs: Long, monotonicNowNs: Long): Long {
        if (sensorNs <= 0L) return sensorNs
        val offset = realtimeNowNs - monotonicNowNs
        val closerToRealtime = Math.abs(realtimeNowNs - sensorNs) < Math.abs(monotonicNowNs - sensorNs)
        return if (closerToRealtime) sensorNs - offset else sensorNs
    }

    /**
     * Whether a frame at [nsecs] may be presented to [surface]; records it
     * when so. Rejects 0 (a SurfaceTexture before its first camera frame) and
     * anything not after the last accepted time.
     */
    fun accept(last: MutableMap<Any, Long>, surface: Any, nsecs: Long): Boolean {
        if (nsecs <= 0L) return false
        val prev = last[surface]
        if (prev != null && nsecs <= prev) return false
        last[surface] = nsecs
        return true
    }
}
