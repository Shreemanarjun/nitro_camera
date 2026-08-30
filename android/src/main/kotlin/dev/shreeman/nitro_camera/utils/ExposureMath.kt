package dev.shreeman.nitro_camera.utils

import kotlin.math.roundToInt

/**
 * Manual-exposure clamping (pure, JVM-testable). Camera2's SENSOR_SENSITIVITY
 * (ISO) and SENSOR_EXPOSURE_TIME (nanoseconds) must stay within the device's
 * advertised ranges — an out-of-range value is silently ignored or, worse,
 * wedges AE. The public API takes doubles; clamp + round to the wire types.
 */
object ExposureMath {
    fun clampIso(iso: Double, min: Int, max: Int): Int =
        iso.roundToInt().coerceIn(minOf(min, max), maxOf(min, max))

    fun clampExposureNanos(nanos: Double, min: Long, max: Long): Long =
        nanos.toLong().coerceIn(minOf(min, max), maxOf(min, max))
}
