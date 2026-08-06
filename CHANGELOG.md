## 0.0.1
- **Initial Release**
* **Export split**: `nitro_camera.dart` now exports a curated surface only.
  The raw FFI layer (`NitroCamera`, FFI structs, codec extensions) moved to
  `package:nitro_camera/native.dart`; the FPS HUD moved to
  `package:nitro_camera/debug.dart`.
* **Typed device model**: `CameraDeviceInfo.position`/`lensType` are
  `CameraPosition`/`CameraLensType` enums; `hardwareLevel` is `HardwareLevel`;
  `physicalDevices` is `List<PhysicalDeviceType>`; `extensions` is
  `List<CameraExtension>`; `CameraDeviceFormat.autoFocusSystem` is
  `AutoFocusSystem`; `videoStabilizationModes` is
  `List<VideoStabilizationMode>`. `DevicePosition` int constants removed.
* **Typed errors**: failures throw `CameraException` subtypes
  (`PermissionException`, `DeviceException`, `SessionException`,
  `CaptureException`, `RecorderException`) carrying stable `domain/code`
  strings, instead of bare `StateError`s. Malformed native payloads now throw
  (`session/malformed-payload`) instead of parsing to a silent empty list.

### Fixed

* **Android**: opening a camera crashed (`NullPointerException`) on devices
  whose HAL returns no `SurfaceTexture` output sizes — external/UVC cameras
  especially; the preview-size resolver now falls back to the requested size.
* **Android**: a `MediaRecorder.stop()` failure (e.g. zero frames reached the
  encoder, so the MP4 was never finalised) returned the truncated, unplayable
  file as a successful `RecordingResult`. The file is now deleted and
  `stopRecording()` throws `RecorderException('recorder/finalize-failed')` on
  both platforms. New: `RecordingFinishedReason.failed`,
  `RecordingResult.isFinalized`.
* **Android**: `ResolvedCameraConfig.pixelFormat` / session state echoed a
  requested `bgra` even though the Android frame pipeline is hard-wired to
  `YUV_420_888`; the native side now clamps to `yuv420` so config and
  delivered `FrameData.format` agree.
* **iOS**: external cameras (USB) and Continuity Cameras (both iOS 17+)
  never appeared in `getAvailableCameraDevices()` — hot-plug events fired for
  devices missing from the rebuilt list. They now enumerate and map to
  `CameraPosition.external` even when they self-report a `front` position.
* `initialize()` without an explicit size/format targeted the platform's first
  enumerated format — 4K on Android, the smallest size on iOS. It now targets
  1080p and negotiates the closest supported size (pass `width`/`height` or a
  `format` for anything else).
* **Android**: async `MediaRecorder` errors (encoder death, mediaserver crash)
  were invisible — no error listener was registered, so `isRecording` stayed
  true forever and a later stop returned a corrupt file. The recording is now
  auto-stopped (file deleted, `failed` reason) and a session `error` event is
  emitted.
* Photos now orient for the PHYSICAL device orientation instead of always
  tagging as portrait: Android folds the device rotation (the locked
  `setTargetOrientation` target, else the display rotation) into
  `JPEG_ORIENTATION` / DNG orientation via the official Camera2 formula; iOS
  sets the photo connection's `videoOrientation` from the locked target
  (previously `setTargetOrientation` was dead code on iOS). Landscape captures
  no longer save 90° off.
* **iOS**: `setFrameFormat` validated against the output's
  `availableVideoPixelFormatTypes` before assigning `videoSettings` — an
  unsupported format raised an uncatchable `NSException` (same crash class as
  vision-camera #4081).
* **Android**: external (USB/UVC) cameras are no longer misreported as phone
  lenses — name is now "External Camera" and lens type `unknown` instead of a
  fabricated wide-angle classification derived from fallback focal lengths.
* `PhotoResult.orientation` / `isMirrored` now report what the saved file
  actually carries (its EXIF/TIFF orientation) instead of guesses: iOS
  hard-coded `front 0 / back 90` and claimed front stills were mirrored (they
  are saved unmirrored); Android echoed the raw sensor orientation, which
  double-rotates on HALs that satisfy `JPEG_ORIENTATION` by rotating pixels.
  `orientation` is the rotation still pending on the file (0 = already
  upright); `isMirrored` reflects an actual EXIF flip.

* `CameraController.frameStream` delivered frames from *other* open sessions
  (multi-cam / the device-switch window); it is now filtered to its session.
* `PreviewMode.platformView` rendered nothing off-Android; it now falls back
  to the texture path (no iOS platform view is registered).
* `PinchToZoomDetector` clamped to a hardcoded 1–8× instead of the device's
  actual zoom range.
* Unknown wire indices from a newer native layer (permission status, event
  type, lens type, position) are clamped/skipped instead of crashing with a
  `RangeError`; unknown session events are dropped from typed event streams.

### Internal

* `CameraController.initializeWithTexture`,
  `CameraConfiguration.toNativeConfig` and `PhotoCaptureOptions.toNative` are
  annotated `@internal`.


