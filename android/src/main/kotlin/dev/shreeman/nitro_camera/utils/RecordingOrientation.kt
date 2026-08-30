package dev.shreeman.nitro_camera.utils

/**
 * Pure recording-orientation math (no Android framework types, so it is
 * JVM-unit-testable — see RecordingOrientationTest). The vision-camera analogue
 * is their `CameraOrientation+degrees.kt` / `+surfaceRotation.kt` pure helpers.
 *
 * Two jobs:
 *  - [effectiveContent]/[isPortrait]: the content orientation the GL renderer
 *    draws with (sensor mount combined with the current device/display rotation).
 *  - [orientSize]: orient a landscape-reported encoder size to that content, so
 *    upright portrait frames are not squished into a 16:9 landscape surface.
 */
object RecordingOrientation {

    /** Effective content orientation (0/90/180/270). Front sensors mirror. */
    fun effectiveContent(sensorOrientation: Int, displayRotation: Int, front: Boolean): Int =
        if (front) (sensorOrientation + displayRotation) % 360
        else (sensorOrientation - displayRotation + 360) % 360

    fun isPortrait(sensorOrientation: Int, displayRotation: Int, front: Boolean): Boolean =
        effectiveContent(sensorOrientation, displayRotation, front) % 180 == 90

    /**
     * Orient a (landscape-reported) encoder size to the content orientation and
     * clamp to even dimensions (H.264 requires even on many devices). Returns
     * (width, height): portrait → tall (w < h), landscape → wide (w > h).
     */
    fun orientSize(width: Int, height: Int, portrait: Boolean): Pair<Int, Int> {
        val long = maxOf(width, height)
        val short = minOf(width, height)
        val w = if (portrait) short else long
        val h = if (portrait) long else short
        return (if (w % 2 == 0) w else w - 1) to (if (h % 2 == 0) h else h - 1)
    }

    /**
     * Picks the encoder size (landscape long-edge form) whose aspect ratio best
     * matches [targetAspect] (>=1, long/short), among [sizes] with long edge
     * <= [maxDim]; ties broken by the largest area. This is the squish fix:
     * choosing purely by area grabbed a 4:3 size for a 16:9 session, stretching
     * the frame. [sizes] are (width, height) pairs. Returns null if empty.
     */
    fun bestEncoderSize(
        sizes: List<Pair<Int, Int>>,
        targetAspect: Float,
        maxDim: Int,
    ): Pair<Int, Int>? {
        val eligible = sizes.filter { maxOf(it.first, it.second) <= maxDim }
        val pool = eligible.ifEmpty { sizes }
        return pool.minWithOrNull(
            compareBy<Pair<Int, Int>> { s ->
                val a = maxOf(s.first, s.second).toFloat() / minOf(s.first, s.second).coerceAtLeast(1)
                Math.round(Math.abs(a - targetAspect) * 100) // 0.01 aspect buckets
            }.thenByDescending { s -> s.first.toLong() * s.second }
        )
    }
}
