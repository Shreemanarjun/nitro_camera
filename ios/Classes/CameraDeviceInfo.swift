import AVFoundation
import CoreMedia
import Foundation

/// Device enumeration + per-device capability reporting (JSON and typed).
///
/// vision-camera analogue: ios/Hybrid Objects/Inputs/HybridCameraDevice.swift
/// (per-device capabilities) + ios/Hybrid Objects/HybridCameraDeviceFactory.swift
/// (discovery). Their capabilities are Nitro hybrid-object properties; ours are
/// a JSON dictionary + the bridge's `CameraDevice` struct.
enum CameraDeviceInfo {

    // MARK: - Devices-JSON cache
    //
    // Enumerating every lens' formats (dozens of AVCaptureDeviceFormat objects
    // across the physical + virtual cameras, each with non-trivial property
    // reads) is multi-second cold on device and delays first camera open. The
    // device *set* only changes on hot-plug, so build the JSON once per process
    // and reuse it, invalidating on connect/disconnect. Guarded by a lock — the
    // method is `@nitroNativeAsync` (off the UI thread) and may be re-entered.
    private static let cacheLock = NSLock()
    private static var cachedDevicesJson: String?
    private static var cacheObserversInstalled = false

    /// Drops the cached devices JSON so the next call rebuilds it.
    static func invalidateDevicesCache() {
        cacheLock.lock()
        cachedDevicesJson = nil
        cacheLock.unlock()
    }

    /// Registers hot-plug observers (once per process) that invalidate the
    /// cache — self-contained so caching is correct even when the app never
    /// enables the higher-level CameraDevicesObserver.
    private static func installCacheInvalidationIfNeeded() {
        cacheLock.lock()
        let install = !cacheObserversInstalled
        cacheObserversInstalled = true
        cacheLock.unlock()
        guard install else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.AVCaptureDeviceWasConnected,
                     Notification.Name.AVCaptureDeviceWasDisconnected] {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                CameraDeviceInfo.invalidateDevicesCache()
            }
        }
    }

    static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        // Physical lenses + virtual (logical multi-cam) devices. Virtual devices
        // are the iOS analogue of Android's LOGICAL_MULTI_CAMERA: they expose
        // constituent physical lenses and seamless zoom switch-over.
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
        ]
        if #available(iOS 13.0, *) {
            deviceTypes.append(.builtInDualWideCamera)
            deviceTypes.append(.builtInTripleCamera)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
    }

    /// All devices' capability dictionaries serialized as a JSON array.
    /// Cached per process (see the cache section above) — instant on warm calls.
    static func devicesJson() -> String {
        installCacheInvalidationIfNeeded()

        cacheLock.lock()
        if let cached = cachedDevicesJson {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Build outside the lock (expensive). Per-device capability building is
        // the hot cost, so fan it out across cores — reading device/format state
        // is thread-safe — instead of the old serial map. A rare concurrent
        // double-build is harmless (idempotent; last writer wins).
        let devices = discoverySession().devices
        var dicts = [[String: Any]](repeating: [:], count: devices.count)
        dicts.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: buf.count) { i in
                buf[i] = deviceInfoDict(for: devices[i])
            }
        }

        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: dicts, options: []),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = "[]"
        }

        cacheLock.lock()
        cachedDevicesJson = json
        cacheLock.unlock()
        return json
    }

    /// Concurrent-streaming camera combinations (multi-cam), iOS 13+ — JSON
    /// array of arrays of device uniqueIDs; "[]" where multi-cam is unsupported.
    static func concurrentCameraIdsJson() -> String {
        guard #available(iOS 13.0, *), AVCaptureMultiCamSession.isMultiCamSupported else {
            return "[]"
        }
        let combos = discoverySession().supportedMultiCamDeviceSets.map { set in
            set.map { $0.uniqueID }.sorted()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: combos),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// vision-camera's `physicalDevices` naming — the SAME strings as Android.
    static func lensTypeName(_ type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera: return "ultra-wide-angle-camera"
        case .builtInTelephotoCamera: return "telephoto-camera"
        default:                      return "wide-angle-camera"
        }
    }

    /// Nominal focal length in mm by lens type — AVFoundation exposes no
    /// physical focal-length API, so report a typical per-lens value (the
    /// Android side reads the real LENS_INFO_AVAILABLE_FOCAL_LENGTHS).
    static func nominalFocalLength(_ type: AVCaptureDevice.DeviceType) -> Double {
        switch type {
        case .builtInUltraWideCamera: return 1.6
        case .builtInTelephotoCamera: return 7.0
        default:                      return 4.2
        }
    }

    static func deviceInfoDict(for device: AVCaptureDevice) -> [String: Any] {
        let position: Int = device.position == .front ? 0 : (device.position == .back ? 1 : 2)
        let lensType: Int
        switch device.deviceType {
        case .builtInUltraWideCamera: lensType = 2
        case .builtInTelephotoCamera: lensType = 3
        default:                      lensType = 1
        }

        // SINGLE pass over device.formats — the enumeration is the hot cost, so
        // compute the max photo dimensions AND build each format's capability
        // dict in one sweep (the old code iterated device.formats twice, reading
        // formatDescription for every format on each pass). `activeFormat` ISO is
        // device-wide, so read it once instead of per format.
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        var maxW = 0, maxH = 0
        var formats: [[String: Any]] = []
        formats.reserveCapacity(device.formats.count)
        for fmt in device.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dim.width), h = Int(dim.height)
            if w > maxW { maxW = w; maxH = h }
            guard w > 0 && h > 0 else { continue }
            let fpsRanges = fmt.videoSupportedFrameRateRanges
            let minFps = fpsRanges.map { $0.minFrameRate }.min() ?? 1.0
            let maxFps = fpsRanges.map { $0.maxFrameRate }.max() ?? 30.0
            var afSystem = "none"
            if #available(iOS 13.0, *) {
                switch fmt.autoFocusSystem {
                case .phaseDetection:    afSystem = "phase-detection"
                case .contrastDetection: afSystem = "contrast-detection"
                default: break
                }
            }
            formats.append([
                "videoWidth":           w,
                "videoHeight":          h,
                "minFps":               minFps,
                "maxFps":               maxFps,
                "minISO":               minISO,
                "maxISO":               maxISO,
                "fieldOfView":          fmt.videoFieldOfView,
                "supportsVideoHdr":     fmt.isVideoHDRSupported,
                "supportsPhotoHdr":     false,
                "supportsDepthCapture": !fmt.supportedDepthDataFormats.isEmpty,
                "autoFocusSystem":      afSystem,
                "videoStabilizationModes": ["off", "standard"],
            ])
        }
        // photoWidth/Height are the device-wide max (identical for every format
        // entry, as before) — patch them in after the max is finalized. This
        // loop touches only the lightweight dicts, no more AVFoundation reads.
        for i in formats.indices {
            formats[i]["photoWidth"] = maxW
            formats[i]["photoHeight"] = maxH
        }

        let minEv = Double(device.minExposureTargetBias)
        let maxEv = Double(device.maxExposureTargetBias)
        let minFocusDist = device.lensPosition > 0 ? Double(device.lensPosition) : 0.0

        // Physical lens composition (vision-camera's physicalDevices) — the
        // SAME strings as Android. A plain camera reports its own lens type; a
        // virtual (logical multi-cam) device lists its constituents'.
        var physicalDevices = [lensTypeName(device.deviceType)]
        var isMultiCam = false
        // neutralZoom: the first virtual-device switch-over factor (the zoom at
        // which a multi-cam device hands off between constituent lenses); 1.0
        // for plain physical cameras.
        var neutralZoom = 1.0
        if #available(iOS 13.0, *), device.isVirtualDevice {
            isMultiCam = true
            physicalDevices = device.constituentDevices.map { lensTypeName($0.deviceType) }
            if let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first {
                neutralZoom = Double(truncating: firstSwitchOver)
            }
        }

        return [
            "id":                   device.uniqueID,
            "name":                 device.localizedName,
            "position":             position,
            "lensType":             lensType,
            // 0: buffers are delivered upright (connection.videoOrientation = .portrait),
            // so the Flutter preview must NOT swap width/height.
            "sensorOrientation":    0,
            "minZoom":              Double(device.minAvailableVideoZoomFactor),
            "maxZoom":              Double(device.maxAvailableVideoZoomFactor),
            "neutralZoom":          neutralZoom,
            "hasFlash":             device.hasFlash,
            "hasTorch":             device.hasTorch,
            "maxPhotoWidth":        maxW,
            "maxPhotoHeight":       maxH,
            "minExposure":          minEv,
            "maxExposure":          maxEv,
            "minFocusDistanceCm":   minFocusDist,
            "isMultiCam":           isMultiCam,
            "supportsLowLightBoost": device.isLowLightBoostSupported,
            // Honest capability report: RAW availability on iOS is only knowable
            // from a LIVE AVCapturePhotoOutput (availableRawPhotoPixelFormatTypes
            // depends on the connected session + active format), so enumeration
            // reports false and the DNG capture path performs the real runtime
            // check — throwing a clear `rawNotSupported` error when absent.
            "supportsRawCapture":   false,
            "supportsFocus":        device.isFocusPointOfInterestSupported,
            "hardwareLevel":        "full",
            "physicalDevices":      physicalDevices,
            // Vendor extensions (Night / HDR / Bokeh...) are an Android-only
            // concept (CameraExtensionCharacteristics); always empty on iOS.
            "extensions":           [String](),
            "focalLength":          nominalFocalLength(device.deviceType),
            "aperture":             Double(device.lensAperture),
            "formats":              formats,
        ]
    }

    static func deviceInfo(for device: AVCaptureDevice) -> CameraDevice {
        let position: Int64 = device.position == .front ? 0 : (device.position == .back ? 1 : 2)
        let lensType: Int64
        switch device.deviceType {
        case .builtInUltraWideCamera: lensType = 2
        case .builtInTelephotoCamera: lensType = 3
        default:                      lensType = 1
        }
        var maxW: Int64 = 0, maxH: Int64 = 0
        for fmt in device.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            if Int64(dim.width) > maxW { maxW = Int64(dim.width); maxH = Int64(dim.height) }
        }
        // Virtual multi-cam devices: neutral zoom = first lens switch-over factor.
        var neutralZoom = 1.0
        if #available(iOS 13.0, *), device.isVirtualDevice,
           let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            neutralZoom = Double(truncating: firstSwitchOver)
        }
        return CameraDevice(
            id: device.uniqueID,
            name: device.localizedName,
            position: position,
            lensType: lensType,
            sensorOrientation: Int64(0), // upright buffers — see JSON variant above
            minZoom: Double(device.minAvailableVideoZoomFactor),
            maxZoom: Double(device.maxAvailableVideoZoomFactor),
            neutralZoom: neutralZoom,
            hasFlash: device.hasFlash ? Int64(1) : Int64(0),
            hasTorch: device.hasTorch ? Int64(1) : Int64(0),
            maxPhotoWidth: maxW,
            maxPhotoHeight: maxH,
            focalLength: nominalFocalLength(device.deviceType), // no public focal-length API
            aperture: Double(device.lensAperture)
        )
    }
}

/// AVCaptureDevice hot-plug observation (wasConnected/wasDisconnected) —
/// external cameras on iPadOS / continuity devices.
///
/// vision-camera analogue: none on iOS (their Android side listens to CameraX
/// device presence); kept beside the device domain it reports on.
final class CameraDevicesObserver {

    /// Emits the device uniqueID (video devices only).
    var onConnected: ((String) -> Void)?
    var onDisconnected: ((String) -> Void)?

    private var connectedObserver: NSObjectProtocol?
    private var disconnectedObserver: NSObjectProtocol?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard connectedObserver == nil else { return }
            let center = NotificationCenter.default
            connectedObserver = center.addObserver(
                forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil
            ) { [weak self] note in
                guard let device = note.object as? AVCaptureDevice,
                      device.hasMediaType(.video) else { return }
                self?.onConnected?(device.uniqueID)
            }
            disconnectedObserver = center.addObserver(
                forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: nil
            ) { [weak self] note in
                guard let device = note.object as? AVCaptureDevice,
                      device.hasMediaType(.video) else { return }
                self?.onDisconnected?(device.uniqueID)
            }
        } else {
            let center = NotificationCenter.default
            if let observer = connectedObserver { center.removeObserver(observer) }
            if let observer = disconnectedObserver { center.removeObserver(observer) }
            connectedObserver = nil
            disconnectedObserver = nil
        }
    }
}
