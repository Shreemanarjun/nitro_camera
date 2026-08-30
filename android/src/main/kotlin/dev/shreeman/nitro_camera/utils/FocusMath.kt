package dev.shreeman.nitro_camera.utils

/**
 * Manual-focus math (pure, JVM-testable). Camera2's LENS_FOCUS_DISTANCE is in
 * DIOPTERS: 0.0 = infinity (far), and LENS_INFO_MINIMUM_FOCUS_DISTANCE (the
 * device's largest focusing power) = nearest. The public API is a normalized
 * 0.0 (far) → 1.0 (near), so map it onto the device's diopter range.
 */
object FocusMath {
    /**
     * [distance01] normalized 0.0 (far) → 1.0 (near); [minFocusDiopters] is
     * LENS_INFO_MINIMUM_FOCUS_DISTANCE (0 = fixed-focus lens). Returns the
     * clamped diopter value for LENS_FOCUS_DISTANCE.
     */
    fun diopters(distance01: Double, minFocusDiopters: Float): Float {
        if (minFocusDiopters <= 0f) return 0f
        val d = distance01.coerceIn(0.0, 1.0)
        return (d * minFocusDiopters).toFloat().coerceIn(0f, minFocusDiopters)
    }
}
