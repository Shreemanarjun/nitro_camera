package dev.shreeman.nitro_camera.utils

/**
 * Pure EXIF/TIFF orientation decoding (values 1-8 per the EXIF spec) into the
 * (pending rotation degrees CW, mirrored) pair reported on `PhotoResult`.
 * Kept free of Android classes so it is unit-testable on the JVM
 * (see ExifOrientationTest).
 */
object ExifOrientation {
    // EXIF spec values (identical to ExifInterface.ORIENTATION_*).
    const val NORMAL = 1
    const val FLIP_HORIZONTAL = 2
    const val ROTATE_180 = 3
    const val FLIP_VERTICAL = 4
    const val TRANSPOSE = 5
    const val ROTATE_90 = 6
    const val TRANSVERSE = 7
    const val ROTATE_270 = 8

    /** Rotation (degrees CW) a viewer must still apply to display upright. */
    fun degrees(tag: Int): Long = when (tag) {
        ROTATE_90, TRANSPOSE -> 90L
        ROTATE_180, FLIP_VERTICAL -> 180L
        ROTATE_270, TRANSVERSE -> 270L
        else -> 0L // NORMAL, FLIP_HORIZONTAL, undefined/unknown
    }

    /** Whether the stored pixels are mirrored (any EXIF flip variant). */
    fun mirrored(tag: Int): Boolean = when (tag) {
        FLIP_HORIZONTAL, FLIP_VERTICAL, TRANSPOSE, TRANSVERSE -> true
        else -> false
    }
}
