package dev.shreeman.nitro_camera.core

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import nitro.nitro_camera_module.CameraDevice
import org.json.JSONArray
import org.json.JSONObject

/**
 * Reads a camera's characteristics into the public device model: the rich
 * JSON payload (formats, zoom/exposure ranges, physical lens composition,
 * vendor extensions, HDR/RAW/depth capabilities) and the light-weight
 * [CameraDevice] struct.
 *
 * vision-camera analogue: android/.../hybrids/inputs/HybridCameraDevice.kt +
 * extensions/CameraInfo+*.kt (their per-capability CameraInfo readers; ours
 * are consolidated here because the payload is built as one JSON document).
 */
class CameraDeviceDetails(
    private val cameraManager: CameraManager,
    private val getCharacteristics: (String) -> CameraCharacteristics,
) {
    fun buildCameraDeviceJson(cameraId: String, chars: CameraCharacteristics): JSONObject {
        val position = when (chars.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_FRONT -> 0
            CameraCharacteristics.LENS_FACING_BACK  -> 1
            else                                     -> 2
        }
        val orientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val hasFlash    = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

        // Zoom: prefer the modern ratio range (API 30, covers <1.0 ultra-wide
        // zoom-out on logical cameras) over the legacy digital-zoom max.
        var minZoom = 1.0
        var maxZoom = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.let {
                minZoom = it.lower.toDouble()
                maxZoom = it.upper.toDouble()
            }
        }

        val map      = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val jpegSizes = map?.getOutputSizes(android.graphics.ImageFormat.JPEG)?.sortedByDescending { it.width * it.height }
        val maxPhotoW = jpegSizes?.firstOrNull()?.width ?: 1920
        val maxPhotoH = jpegSizes?.firstOrNull()?.height ?: 1080

        val focalArray = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val focalLength = focalArray?.firstOrNull() ?: 3.5f
        val apertures  = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)
        val aperture   = apertures?.firstOrNull() ?: 1.8f

        val lensType = when {
            focalLength < 2.3f -> 2  // ultra-wide
            focalLength > 6.0f -> 3  // telephoto
            else               -> 1  // wide-angle
        }

        val lensName = when (lensType) { 2 -> "Ultra Wide" 3 -> "Telephoto" else -> "Wide" }
        val name     = if (position == 0) "Front Camera" else "$lensName Camera"

        val evRange  = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val evStep   = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toDouble() ?: 1.0
        val minEv    = if (evRange != null && evStep != 0.0) evRange.lower * evStep else -4.0
        val maxEv    = if (evRange != null && evStep != 0.0) evRange.upper * evStep else  4.0

        // Capabilities → RAW / depth / logical multi-cam flags.
        val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: intArrayOf()
        val supportsRaw = caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW)
        val supportsDepth = caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT)
        val isMultiCam = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)

        val hardwareLevel = when (chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY  -> "legacy"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
            else                                                         -> "full"
        }

        // Physical lens composition (vision-camera's physicalDevices). A plain
        // camera reports its own lens type; a logical camera lists its members'.
        val physical = JSONArray()
        fun lensTypeName(focal: Float) = when {
            focal < 2.3f -> "ultra-wide-angle-camera"
            focal > 6.0f -> "telephoto-camera"
            else         -> "wide-angle-camera"
        }
        if (isMultiCam && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            for (physId in chars.physicalCameraIds) {
                val pf = try {
                    getCharacteristics(physId)
                        .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.firstOrNull()
                } catch (_: Exception) { null }
                physical.put(lensTypeName(pf ?: focalLength))
            }
        } else {
            physical.put(lensTypeName(focalLength))
        }

        // Focus: LENS_INFO_MINIMUM_FOCUS_DISTANCE is in diopters; 0 = fixed-focus.
        val minFocusDiopters = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
        val minFocusDistanceCm = if (minFocusDiopters > 0f) (100.0 / minFocusDiopters) else 0.0
        val afModes = chars.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: intArrayOf()
        val supportsFocus = afModes.any { it != CameraCharacteristics.CONTROL_AF_MODE_OFF }

        // ISO + field of view (from the physical sensor size).
        val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val fieldOfView = if (sensorSize != null && focalLength > 0f) {
            Math.toDegrees(2.0 * Math.atan2(sensorSize.width / 2.0, focalLength.toDouble()))
        } else 69.4

        // Stabilization modes (digital EIS + optical OIS).
        val stabModes = JSONArray().apply { put("off") }
        val eis = chars.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES) ?: intArrayOf()
        if (eis.contains(CameraCharacteristics.CONTROL_VIDEO_STABILIZATION_MODE_ON)) stabModes.put("standard")
        val ois = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION) ?: intArrayOf()
        if (ois.contains(CameraCharacteristics.LENS_OPTICAL_STABILIZATION_MODE_ON)) stabModes.put("cinematic")

        // Vendor extensions (Night / HDR / Bokeh...), API 31+ — query-only.
        val extensions = JSONArray()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val extChars = cameraManager.getCameraExtensionCharacteristics(cameraId)
                for (ext in extChars.supportedExtensions) {
                    extensions.put(
                        when (ext) {
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_AUTOMATIC -> "auto"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_FACE_RETOUCH -> "face-retouch"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_BOKEH -> "bokeh"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_HDR -> "hdr"
                            android.hardware.camera2.CameraExtensionCharacteristics.EXTENSION_NIGHT -> "night"
                            else -> "unknown-$ext"
                        }
                    )
                }
            } catch (_: Exception) { /* extensions unsupported on this device */ }
        }

        // Real fps ranges from the AE target ranges (was hardcoded 15–30).
        val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        val deviceMinFps = fpsRanges?.minOfOrNull { it.lower }?.toDouble() ?: 15.0
        val deviceMaxFps = fpsRanges?.maxOfOrNull { it.upper }?.toDouble() ?: 30.0

        // 10-bit HDR video profiles (API 33+).
        val supportsVideoHdr = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DYNAMIC_RANGE_TEN_BIT)
        val supportsPhotoHdr = (0 until extensions.length()).any { extensions.getString(it) == "hdr" }

        val autoFocusSystem = if (supportsFocus) "contrast-detection" else "none"

        val formatsArr = JSONArray()
        val videoSizes = map?.getOutputSizes(android.graphics.ImageFormat.YUV_420_888)
            ?.sortedByDescending { it.width * it.height } ?: emptyList()

        for (size in videoSizes) {
            // High-speed ranges only apply to specific sizes; report the
            // device-wide AE range, capped to 60 fps for oversized streams
            // (large YUV streams can't sustain high-speed rates).
            val area = size.width.toLong() * size.height
            val maxFpsForSize = if (area > 1920L * 1080 && deviceMaxFps > 30.0) 30.0 else deviceMaxFps
            val fmt = JSONObject()
            fmt.put("photoWidth",  maxPhotoW)
            fmt.put("photoHeight", maxPhotoH)
            fmt.put("videoWidth",  size.width)
            fmt.put("videoHeight", size.height)
            fmt.put("minFps",      deviceMinFps)
            fmt.put("maxFps",      maxFpsForSize)
            if (isoRange != null) {
                fmt.put("minISO", isoRange.lower.toDouble())
                fmt.put("maxISO", isoRange.upper.toDouble())
            }
            fmt.put("fieldOfView", fieldOfView)
            fmt.put("supportsVideoHdr", supportsVideoHdr)
            fmt.put("supportsPhotoHdr", supportsPhotoHdr)
            fmt.put("supportsDepthCapture", supportsDepth)
            fmt.put("autoFocusSystem", autoFocusSystem)
            fmt.put("videoStabilizationModes", stabModes)
            formatsArr.put(fmt)
        }

        return JSONObject().apply {
            put("id",                  cameraId)
            put("name",                name)
            put("position",            position)
            put("lensType",            lensType)
            put("sensorOrientation",   orientation)
            put("minZoom",             minZoom)
            put("maxZoom",             maxZoom)
            put("neutralZoom",         1.0)
            put("hasFlash",            hasFlash)
            put("hasTorch",            hasFlash) // Android: torch iff flash unit
            put("maxPhotoWidth",       maxPhotoW)
            put("maxPhotoHeight",      maxPhotoH)
            put("minExposure",         minEv)
            put("maxExposure",         maxEv)
            put("minFocusDistanceCm",  minFocusDistanceCm)
            put("isMultiCam",          isMultiCam)
            put("supportsRawCapture",  supportsRaw)
            put("supportsFocus",       supportsFocus)
            put("hardwareLevel",       hardwareLevel)
            put("physicalDevices",     physical)
            put("extensions",          extensions)
            put("focalLength",         focalLength.toDouble())
            put("aperture",            aperture.toDouble())
            put("formats",             formatsArr)
        }
    }

    fun buildCameraDevice(cameraId: String, chars: CameraCharacteristics): CameraDevice {
        val position = when (chars.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_FRONT -> 0L
            CameraCharacteristics.LENS_FACING_BACK  -> 1L
            else                                     -> 2L
        }
        val orientation = (chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0).toLong()
        val map   = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(android.graphics.ImageFormat.JPEG)?.sortedByDescending { it.width }
        val maxZoom = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        val hasFlash = if (chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true) 1L else 0L

        val focalArray = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val focalLength = focalArray?.firstOrNull() ?: 3.5f
        val apertures  = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)
        val aperture   = apertures?.firstOrNull() ?: 1.8f

        val lensType = when {
            focalLength < 2.3f -> 2L // ultra-wide
            focalLength > 6.0f -> 3L // telephoto
            else               -> 1L // wide-angle
        }

        return CameraDevice(
            id                = cameraId,
            name              = if (position == 0L) "Front Camera" else "Lens $focalLength",
            position          = position,
            lensType          = lensType,
            sensorOrientation = orientation,
            minZoom           = 1.0,
            maxZoom           = maxZoom,
            neutralZoom       = 1.0,
            hasFlash          = hasFlash,
            hasTorch          = hasFlash,
            maxPhotoWidth     = sizes?.firstOrNull()?.width?.toLong() ?: 1280L,
            maxPhotoHeight    = sizes?.firstOrNull()?.height?.toLong() ?: 720L,
            focalLength       = focalLength.toDouble(),
            aperture          = aperture.toDouble()
        )
    }
}
