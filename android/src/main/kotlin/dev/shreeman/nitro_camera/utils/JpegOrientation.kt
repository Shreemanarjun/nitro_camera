package dev.shreeman.nitro_camera.utils

/**
 * The Camera2 JPEG_ORIENTATION formula (the official `getJpegOrientation`
 * sample from the CaptureRequest docs): how many degrees the HAL must rotate
 * a still so it displays upright for the CURRENT physical device orientation.
 * Pure so it is JVM-unit-testable (see JpegOrientationTest).
 */
object JpegOrientation {

    /**
     * [sensorOrientation] — CameraCharacteristics.SENSOR_ORIENTATION (0/90/180/270).
     * [deviceOrientationDeg] — physical device rotation, CLOCKWISE from natural
     * portrait (the OrientationEventListener convention, bucketed to
     * quadrants). Pass -1 for unknown: falls back to sensor orientation, i.e.
     * the correct answer in natural portrait.
     * [isFrontFacing] — front sensors are mirrored, so the device rotation is
     * applied in the opposite direction.
     */
    fun compute(sensorOrientation: Int, deviceOrientationDeg: Int, isFrontFacing: Boolean): Int {
        if (deviceOrientationDeg < 0) return normalize(sensorOrientation)
        val device = normalize(deviceOrientationDeg)
        val signed = if (isFrontFacing) -device else device
        return normalize(sensorOrientation + signed)
    }

    /**
     * Display rotation (Display.getRotation() as degrees) → physical device
     * rotation. They are inverses: a device physically rotated 90° clockwise
     * has its content counter-rotated, reporting Surface.ROTATION_270.
     */
    fun deviceOrientationFromDisplayRotation(displayRotationDeg: Int): Int =
        normalize(360 - displayRotationDeg)

    private fun normalize(deg: Int): Int = ((deg % 360) + 360) % 360
}
