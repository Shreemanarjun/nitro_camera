## 0.0.2 - 2026-08-08

Bug-fix release, focused on video recording. Some entries were previously
listed under `0.0.1`; they never shipped in it.

### Fixed

* **Android**: `RecordingResult.durationMs` was inflated by the encoder's
  finalize latency — the end timestamp was sampled *after* `MediaRecorder.stop()`
  returned (100–300 ms on hardware, seconds on the emulator, so a 2 s clip
  reported 4.7 s). It now reads the finalized container's own duration
  (paused spans already excluded), with a stop-requested wall clock as
  fallback.
* **Videos no longer save sideways.** Recordings ignored the requested
  orientation and were stored in sensor orientation, so every player showed
  them rotated.
* **`isRecording` no longer gets stuck on.** When a recording ended by itself —
  a duration or file-size limit, or an encoder failure — nothing told Dart, so
  apps kept showing a live recording that had already finished.
* **Encoder crashes are no longer silent.** A dying recorder now stops the
  recording, deletes the unusable file and emits an `error` event, instead of
  leaving a corrupt file to be returned later.
* **Photos no longer save 90° off** in landscape, on both platforms.
* `PhotoResult.orientation` / `isMirrored` now describe the saved file
  accurately instead of guessing per platform.
* A failed stop no longer returns a truncated, unplayable file as a success —
  it throws `RecorderException('recorder/finalize-failed')`. Adds
  `RecordingFinishedReason.failed` and `RecordingResult.isFinalized`.
* `initialize()` without a size or format now targets 1080p instead of the
  platform's first format (which was 4K on Android, the smallest size on iOS).
* **iOS**: an unsupported `setFrameFormat` value crashed the app; it is now
  rejected safely.
* **iOS**: external and Continuity Cameras (iOS 17+) now appear in
  `getAvailableCameraDevices()`.
* **Android**: opening a camera no longer crashes on external/UVC devices whose
  driver reports no preview sizes.
* **Android**: external cameras are labelled as such instead of being
  misreported as phone lenses.
* **Android**: session state no longer reports `bgra` when frames are actually
  delivered as `yuv420`.

### Changed

* Upgraded to nitro 0.5.17, which fixes a small memory leak on every async
  native call (photo capture, recording stop, `configure`).

### Internal

* Test coverage raised to 100% of the Dart source (484 tests), plus 16
  on-device tests that exercise recording combined with backgrounding, lens
  switches, filters, scanning and frame processing — these found the two
  recording bugs above.

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
