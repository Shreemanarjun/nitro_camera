package dev.shreeman.nitro_camera.extensions

import android.hardware.camera2.CameraCharacteristics

/**
 * Whether this camera faces the user (LENS_FACING_FRONT).
 *
 * vision-camera analogue: android/.../extensions/CameraInfo+utils.kt
 * (lens-facing reads on their CameraInfo wrapper).
 */
val CameraCharacteristics.isFrontFacing: Boolean
    get() = get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
