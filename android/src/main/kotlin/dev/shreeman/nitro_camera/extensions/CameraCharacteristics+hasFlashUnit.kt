package dev.shreeman.nitro_camera.extensions

import android.hardware.camera2.CameraCharacteristics

/**
 * Whether this camera has a physical flash unit (front sensors usually
 * don't). Gates every FLASH_MODE / AE-flash-mode request — flash-less HALs
 * ignore or reject them.
 *
 * vision-camera analogue: android/.../extensions/CameraInfo+utils.kt
 * (their `CameraInfo.hasFlashUnit` read).
 */
val CameraCharacteristics.hasFlashUnit: Boolean
    get() = get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
