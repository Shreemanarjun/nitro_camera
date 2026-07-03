package dev.shreeman.nitro_camera

/**
 * Pure, unit-testable geometry for the GL preview transform (no Android deps).
 *
 * The preview-stretch bugs came from the renderer computing an aspect crop that
 * didn't match the displayed (rotated) content. This isolates that math so it can
 * be verified in a JVM unit test (see `NitraFrameTransformTest`).
 */
object NitraFrameTransform {

    /** True when the sensor is mounted at 90°/270° (content is rotated for display). */
    fun isRotated(sensorOrientation: Int): Boolean =
        sensorOrientation == 90 || sensorOrientation == 270

    /**
     * Aspect (w/h) of the camera content **as displayed** — i.e. after the
     * sensor-orientation rotation. For a 90/270 sensor the axes are swapped.
     */
    fun displayContentAspect(sensorOrientation: Int, contentW: Int, contentH: Int): Float =
        if (isRotated(sensorOrientation)) contentH.toFloat() / contentW
        else contentW.toFloat() / contentH

    /**
     * Cover-crop factors `(cropX, cropY)` in `[0,1]` — the fraction of the
     * (rotated) content to sample on each axis so it fills the surface without
     * distortion. Exactly one is < 1 (the over-long axis is cropped).
     */
    fun coverCrop(
        sensorOrientation: Int,
        contentW: Int,
        contentH: Int,
        surfaceW: Int,
        surfaceH: Int,
    ): FloatArray {
        val contentAspect = displayContentAspect(sensorOrientation, contentW, contentH)
        val outputAspect = surfaceW.toFloat() / surfaceH
        var cropX = 1.0f
        var cropY = 1.0f
        if (contentAspect > outputAspect) {
            cropX = outputAspect / contentAspect // content wider → crop sides
        } else {
            cropY = contentAspect / outputAspect // content taller → crop top/bottom
        }
        return floatArrayOf(cropX, cropY)
    }

    /**
     * Aspect (w/h) actually shown after [coverCrop] fills the surface. For a
     * correct (un-stretched) preview this MUST equal the surface aspect.
     */
    fun displayedAspect(
        sensorOrientation: Int,
        contentW: Int,
        contentH: Int,
        surfaceW: Int,
        surfaceH: Int,
    ): Float {
        val contentAspect = displayContentAspect(sensorOrientation, contentW, contentH)
        val (cropX, cropY) = coverCrop(sensorOrientation, contentW, contentH, surfaceW, surfaceH)
        return contentAspect * (cropX / cropY)
    }
}
