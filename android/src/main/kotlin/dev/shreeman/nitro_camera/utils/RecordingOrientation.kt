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
}
