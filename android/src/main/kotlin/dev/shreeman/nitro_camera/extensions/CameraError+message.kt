package dev.shreeman.nitro_camera.extensions

import android.hardware.camera2.CameraDevice as AndroidCameraDevice

/**
 * Human-readable message for a [android.hardware.camera2.CameraDevice.StateCallback]
 * error code — vision-camera's error taxonomy (their `StateError.reason`),
 * mapped onto the Camera2 codes. A bare "error 4" in an event/log is
 * undiagnosable in the field; these strings say what actually happened.
 *
 * vision-camera analogue: android/.../extensions/StateError+reason.kt.
 */
internal fun cameraErrorMessage(code: Int): String = when (code) {
    AndroidCameraDevice.StateCallback.ERROR_CAMERA_IN_USE ->
        "Camera device is already in use! (ERROR_CAMERA_IN_USE)"
    AndroidCameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE ->
        "The maximum number of open cameras has been reached — close another camera first! (ERROR_MAX_CAMERAS_IN_USE)"
    AndroidCameraDevice.StateCallback.ERROR_CAMERA_DISABLED ->
        "Camera is disabled, probably due to a device policy! (ERROR_CAMERA_DISABLED)"
    AndroidCameraDevice.StateCallback.ERROR_CAMERA_DEVICE ->
        "Encountered a fatal camera device error! (ERROR_CAMERA_DEVICE)"
    AndroidCameraDevice.StateCallback.ERROR_CAMERA_SERVICE ->
        "Encountered a fatal camera service error! (ERROR_CAMERA_SERVICE)"
    else -> "Encountered an unknown camera error! ($code)"
}
