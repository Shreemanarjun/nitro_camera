// Starter for HybridNitroCameraProtocol — written once by `nitrogen link`; yours to edit.
import Combine
import Foundation

public class NitroCameraModuleImpl: HybridNitroCameraProtocol {
    public init() {}

    public func requestCameraPermission() async throws -> Int64 { fatalError("TODO: implement NitroCameraModuleImpl.requestCameraPermission") }
    public func getCameraPermissionStatus() -> Int64 { fatalError("TODO: implement NitroCameraModuleImpl.getCameraPermissionStatus") }
    public func requestMicrophonePermission() async throws -> Int64 { fatalError("TODO: implement NitroCameraModuleImpl.requestMicrophonePermission") }
    public func getMicrophonePermissionStatus() -> Int64 { fatalError("TODO: implement NitroCameraModuleImpl.getMicrophonePermissionStatus") }
    public func getAvailableCameraDevicesJson() async throws -> String { fatalError("TODO: implement NitroCameraModuleImpl.getAvailableCameraDevicesJson") }
    public func getAvailableCameraDevices() -> [CameraDevice] { fatalError("TODO: implement NitroCameraModuleImpl.getAvailableCameraDevices") }
    public func getDeviceCount() -> Int64 { fatalError("TODO: implement NitroCameraModuleImpl.getDeviceCount") }
    public func getDevice(index: Int64) -> CameraDevice { fatalError("TODO: implement NitroCameraModuleImpl.getDevice") }
    public func openCamera(deviceId: String, width: Int64, height: Int64, fps: Int64, enableAudio: Int64, frameWidth: Int64, frameHeight: Int64) async throws -> Int64 { fatalError("TODO: implement NitroCameraModuleImpl.openCamera") }
    public func closeCamera(textureId: Int64) async throws -> Void { fatalError("TODO: implement NitroCameraModuleImpl.closeCamera") }
    public func startPreview(textureId: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.startPreview") }
    public func stopPreview(textureId: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.stopPreview") }
    public func setZoom(textureId: Int64, zoom: Double) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setZoom") }
    public func setFocusPoint(textureId: Int64, x: Double, y: Double) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setFocusPoint") }
    public func setAutoFocus(textureId: Int64, mode: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setAutoFocus") }
    public func setFocusDistance(textureId: Int64, distance: Double) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setFocusDistance") }
    public func setManualExposure(textureId: Int64, iso: Double, exposureNanos: Double) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setManualExposure") }
    public func startHighSpeedRecording(textureId: Int64, path: String, fps: Int64) async throws -> Int64 { fatalError("TODO: implement NitroCameraModuleImpl.startHighSpeedRecording") }
    public func stopHighSpeedRecording(textureId: Int64) async throws -> RecordingResult { fatalError("TODO: implement NitroCameraModuleImpl.stopHighSpeedRecording") }
    public func setExposure(textureId: Int64, value: Double) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setExposure") }
    public func setFlash(textureId: Int64, mode: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setFlash") }
    public func setTorch(textureId: Int64, enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setTorch") }
    public func setWhiteBalance(textureId: Int64, temperature: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setWhiteBalance") }
    public func setHdr(textureId: Int64, enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setHdr") }
    public func takePhoto(textureId: Int64) async throws -> PhotoResult { fatalError("TODO: implement NitroCameraModuleImpl.takePhoto") }
    public func startVideoRecording(textureId: Int64, outputPath: String, options: RecordingOptions) async throws -> Void { fatalError("TODO: implement NitroCameraModuleImpl.startVideoRecording") }
    public func stopVideoRecording(textureId: Int64) async throws -> RecordingResult { fatalError("TODO: implement NitroCameraModuleImpl.stopVideoRecording") }
    public func pauseRecording(textureId: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.pauseRecording") }
    public func resumeRecording(textureId: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.resumeRecording") }
    public func cancelRecording(textureId: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.cancelRecording") }
    public func enableFrameProcessing(textureId: Int64, enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.enableFrameProcessing") }
    public func setFrameFormat(textureId: Int64, format: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setFrameFormat") }
    public func setSamplingRate(textureId: Int64, samplingRate: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setSamplingRate") }
    public func setFilterShader(textureId: Int64, shaderSource: String) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setFilterShader") }
    public func updateOverlay(textureId: Int64, overlayData: Data) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.updateOverlay") }
    public func configure(textureId: Int64, config: CameraConfig) async throws -> ResolvedConfig { fatalError("TODO: implement NitroCameraModuleImpl.configure") }
    public func getSessionStateJson(textureId: Int64) -> String { fatalError("TODO: implement NitroCameraModuleImpl.getSessionStateJson") }
    public func setVideoStabilization(textureId: Int64, mode: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setVideoStabilization") }
    public func setLowLightBoost(textureId: Int64, enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setLowLightBoost") }
    public func setTorchLevel(textureId: Int64, level: Double) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setTorchLevel") }
    public func lockExposure(textureId: Int64, locked: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.lockExposure") }
    public func lockFocus(textureId: Int64, locked: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.lockFocus") }
    public func lockWhiteBalance(textureId: Int64, locked: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.lockWhiteBalance") }
    public func setTargetOrientation(textureId: Int64, degrees: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setTargetOrientation") }
    public func setDistortionCorrection(textureId: Int64, enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setDistortionCorrection") }
    public func enableOrientationEvents(enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.enableOrientationEvents") }
    public func enableDeviceAvailabilityEvents(enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.enableDeviceAvailabilityEvents") }
    public func setKeepScreenOn(enabled: Int64) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setKeepScreenOn") }
    public func setNativeDetector(textureId: Int64, detector: String) -> Void { fatalError("TODO: implement NitroCameraModuleImpl.setNativeDetector") }
    public func getConcurrentCameraIdsJson() -> String { fatalError("TODO: implement NitroCameraModuleImpl.getConcurrentCameraIdsJson") }
    public func takePhotoWithOptions(textureId: Int64, options: PhotoOptions) async throws -> PhotoResult { fatalError("TODO: implement NitroCameraModuleImpl.takePhotoWithOptions") }
    public func takeSnapshot(textureId: Int64) async throws -> PhotoResult { fatalError("TODO: implement NitroCameraModuleImpl.takeSnapshot") }
    public func reset() -> Void { fatalError("TODO: implement NitroCameraModuleImpl.reset") }
    public var frameStream: AnyPublisher<CameraFrame, Never> { fatalError("TODO: implement NitroCameraModuleImpl.frameStream") }
    public var eventStream: AnyPublisher<CameraEvent, Never> { fatalError("TODO: implement NitroCameraModuleImpl.eventStream") }
}
