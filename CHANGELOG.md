## 0.1.0

First curated API release — one batched set of breaking changes; see
`MIGRATION.md` for the mechanical mapping.

### Breaking

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

## 0.0.1

* Initial development release: vision-camera-style camera engine (photo /
  video / frame processing / code scanning) on the nitro FFI bridge.
