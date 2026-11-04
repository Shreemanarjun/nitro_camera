## 0.0.3 - 2026-11-04

### Added

* **Separate frame-processor size** (Android) — `frameWidth` / `frameHeight` on
  `CameraView` and `initialize()`: a sharp preview over small analysis frames
  (vision-camera's frame-output `targetResolution`).
* **Photo output opt-out** (Android) — `photo: false` leaves the JPEG stream out
  of the session for preview + frames only; photo/snapshot calls then throw
  `CaptureException('capture/photo-disabled')`.
* **Direct frame delivery** — `CameraFrameProcessor.attachDirect()`: the worker
  isolate subscribes to the native frame stream itself (no UI-isolate hop) and
  processes only the newest frame of each batch. ~7 % faster end-to-end in the
  1000-QR throughput benchmark, which now matches react-native-vision-camera on
  the same phone (both at the 30 fps camera limit).

* **Direct preview** (Android) — a `PreviewMode.texture` preview can take the
  camera's buffers straight into the Flutter texture, with no GL copy: the
  `NitraGLThread` disappears and the app uses ~3 % less of a core (OnePlus
  CPH2447, 1000-QR benchmark: 47.2 % vs 50.3 % mean CPU, 274 vs 285 MB RSS,
  same throughput). `CameraView` uses it for its default Texture mode;
  `CameraController(directPreview: true)` opts in elsewhere. Dart rotates,
  mirrors and cover-crops the raw buffer from the new
  `NitroCamera.getPreviewTransform` / `CameraController.previewTransform`. The
  session falls back to the GL renderer by itself when a shader, lens
  undistortion, a platform view or GL recording needs it
  (`CameraEventType.previewTransformChanged`). Only with an ImageReader-backed
  texture (`handlesCropAndRotation() == false`); otherwise GL as before.

### Fixed

* **Android**: a DNG request on a camera that advertises RAW but never delivers a
  RAW frame (e.g. OnePlus logical multi-cameras) now throws
  `CaptureException('capture/raw-unavailable')` instead of an untyped native
  error. Later DNG requests on that camera fail immediately (no second preview
  freeze), and the camera device is reopened — the HAL left it broken, which
  used to surface as `ERROR_CAMERA_DEVICE` on the next operation.

* **Android**: the front camera's GL preview (platform view, shaders, lens
  undistortion) was not mirrored — the opposite of the stock selfie preview.
  It is now mirrored in screen space after rotation, like the direct preview.
  Recordings keep their existing (un-mirrored) output.

* Scanner: small QR codes (2.5–4 px modules) now decode — a 2× upscaled
  centre pass joins the adaptive ladder.
* `CameraFrameProcessor`: a handler that throws no longer silently kills the
  worker isolate (no more frames, no log). The frame counts as a miss, the
  first error is printed, and processing continues.

### Changed

* **Android startup**: the pre-wired recorder surface (MediaCodec persistent
  surface + dormant MediaRecorder, ~80 ms) is now built while the camera
  hardware opens instead of after it. Cold start on a OnePlus CPH2447: camera
  opened → streams created 194 → 154 ms, first camera frames 772 → 720 ms
  (medians, 16 vs 14 launches); instant recording start is unchanged.

* Upgraded to nitro 0.8.5 (weak Dart DL symbols — fixes the iOS
  "duplicate symbol" link error with two nitro SPM plugins, nitro_ecosystem#61).
* `NitroCamera.openCamera` takes a trailing `directPreview` argument (the
  raw native API; `CameraController` passes it for you).
* **Android**: frames are posted to Dart from the camera thread (a direct hot
  flow) instead of hopping through a `Dispatchers.Default` collector:
  native → Dart handler p50 1.3 → 0.5 ms, p90 3.6 → 1.6 ms. With no buffer
  left to overflow, Android no longer emits `frameDropped` for a slow Dart
  consumer; the Dart side coalesces a busy port instead.
* `attachDirect` frames are copied into one reused `NitroBuffer`, so a
  `@zeroCopy` native call (e.g. nitro_zxing's `decodeLuma`) takes them by
  pointer with no second copy. `FrameData.bytes` is borrowed in this mode:
  valid only during the handler call.
* `resolvedConfig` / `onConfigResolved` are now populated when the camera is
  opened from a plain `width`/`height`/`fps` request (no format): the values
  come from the native session read-back, so a requested 60 fps that the
  hardware caps at 30 is reported as 30. **Breaking:**
  `ResolvedCameraConfig.format` is now nullable (null in that case).

## 0.0.2

### Added

* **High-speed (slow-motion) recording** — `startHighSpeedRecording(path, fps)` /
  `stopHighSpeedRecording()`: 120/240 fps → 8× slow-mo.
* **Native detector plugin registry** — `NitraDetectors.register(name, factory)`;
  select custom detectors from Dart by name. `barcode` / `face` built-in.
* **Manual focus & exposure** — `setFocusDistance`, `setManualExposure`,
  `setAutoExposure` (clamped natively).
* **Keep-screen-on** — `setKeepScreenOn(bool)` (FFI, no extra plugin).
* **Frame helpers** — `FrameData.resized / cropped / rotated`.
* **Scanner ROI** — `CodeScanner(windowFraction: …)`.
* **Multi-cam discovery** — typed `ConcurrentCameraSet` + `getConcurrentCameraSets`.

### Fixed

* Android: recorded video no longer squished — encoder size matches session aspect.
* Android: fixed a persistent-surface teardown race that could crash the camera.
* iOS: back↔front switch with manual white balance no longer crashes.
* RAW/DNG on HALs that gate it now fails fast + falls back to JPEG (no freeze).
* **Android**: `RecordingResult.durationMs` was inflated by the encoder's
  finalize latency (a 2 s clip could report 4.7 s). It now reads the finalized
  container's own duration, with a stop-requested wall clock as fallback.
* **Videos no longer save sideways** — recordings ignored the requested
  orientation and were stored in sensor orientation.
* **`isRecording` no longer gets stuck on** when a recording ends by itself
  (duration/file-size limit or encoder failure) — Dart is now notified.
* **Encoder crashes are no longer silent** — a dying recorder stops the
  recording, deletes the unusable file and emits an `error` event.
* **Photos no longer save 90° off** in landscape, on both platforms;
  `PhotoResult.orientation` / `isMirrored` now describe the saved file accurately.
* A failed stop no longer returns a truncated, unplayable file as success — it
  throws `RecorderException('recorder/finalize-failed')`. Adds
  `RecordingFinishedReason.failed` and `RecordingResult.isFinalized`.
* `initialize()` without a size/format now targets 1080p instead of the
  platform's first format (4K on Android, smallest on iOS).
* **iOS**: an unsupported `setFrameFormat` value no longer crashes the app.
* **iOS**: external and Continuity Cameras (iOS 17+) now appear in
  `getAvailableCameraDevices()`.
* **Android**: opening external/UVC cameras that report no preview sizes no
  longer crashes; they're also labelled as external instead of phone lenses.
* **Android**: session state no longer reports `bgra` when frames are delivered
  as `yuv420`.

### Changed

* Upgraded to nitro 0.7.5.

## 0.0.1 - 2026-07-12

Initial release.

* **Curated exports**: `nitro_camera.dart` exposes the high-level API only.
  The raw FFI layer moved to `package:nitro_camera/native.dart` and the FPS HUD
  to `package:nitro_camera/debug.dart`.
* **Typed device model**: positions, lens types, hardware level, extensions,
  auto-focus system and stabilization modes are enums rather than ints.
* **Typed errors**: failures throw `CameraException` subtypes
  (`PermissionException`, `DeviceException`, `SessionException`,
  `CaptureException`, `RecorderException`) with stable `domain/code` strings.

### Fixed

* `frameStream` delivered frames from other open sessions; it is now scoped to
  its own session.
* `PreviewMode.platformView` rendered nothing off-Android; it now falls back to
  the texture path.
* Pinch-to-zoom clamped to a hardcoded 1–8× instead of the device's real range.
* Unknown values from a newer native layer are skipped instead of throwing a
  `RangeError`.
