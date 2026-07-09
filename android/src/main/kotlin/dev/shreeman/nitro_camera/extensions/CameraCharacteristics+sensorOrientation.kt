package dev.shreeman.nitro_camera.extensions

import android.hardware.camera2.CameraCharacteristics

/**
 * SENSOR_ORIENTATION in degrees, with a caller-chosen [default] for the
 * (theoretical) null case — call sites differ on the safe fallback (0 for
 * metadata, 90 for the renderer's mount assumption), which is why this is a
 * function and not a val.
 *
 * vision-camera analogue: android/.../extensions/CameraOrientation+degrees.kt.
 */
fun CameraCharacteristics.sensorOrientationDegrees(default: Int = 0): Int =
    get(CameraCharacteristics.SENSOR_ORIENTATION) ?: default
