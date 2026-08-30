package dev.shreeman.nitro_camera.utils

/**
 * Picks a constrained-high-speed video config for a slow-mo request. Pure and
 * JVM-testable — the session reads the real configs from
 * `StreamConfigurationMap.getHighSpeedVideoSizes()` /
 * `getHighSpeedVideoFpsRangesFor(size)` and maps them into [Config]s.
 *
 * A high-speed session requires the request's FPS range to be one the device
 * advertises for the exact size, so we match size first, then the fps.
 */
object HighSpeedConfig {
    /** One advertised high-speed capability. [fpsMin]==[fpsMax] is a fixed slow-mo rate. */
    data class Config(val width: Int, val height: Int, val fpsMin: Int, val fpsMax: Int)

    /**
     * Best config for [reqWidth]×[reqHeight] at [reqFps]. Prefers an exact-size
     * match whose range covers [reqFps]; among those, the tightest range with
     * the highest max (a fixed [reqFps,reqFps] beats a 30..reqFps). Falls back
     * to the closest-area size that supports [reqFps]. Returns null when no
     * advertised config reaches [reqFps].
     */
    fun pick(configs: List<Config>, reqWidth: Int, reqHeight: Int, reqFps: Int): Config? {
        val reachable = configs.filter { it.fpsMax >= reqFps && reqFps >= it.fpsMin }
        if (reachable.isEmpty()) return null
        val exact = reachable.filter { it.width == reqWidth && it.height == reqHeight }
        val pool = exact.ifEmpty { reachable }
        return pool.minWithOrNull(
            // exact-size first, then tightest range (smaller span), then higher max.
            compareBy<Config> { areaDiff(it, reqWidth, reqHeight) }
                .thenBy { it.fpsMax - it.fpsMin }
                .thenByDescending { it.fpsMax }
        )
    }

    private fun areaDiff(c: Config, w: Int, h: Int): Long =
        Math.abs(c.width.toLong() * c.height - w.toLong() * h)

    /** True when [fps] is a high-speed rate the normal session can't deliver. */
    fun isHighSpeed(fps: Int): Boolean = fps > 60
}
