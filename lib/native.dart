/// The low-level FFI boundary of nitro_camera — the raw [NitroCamera] hybrid
/// module, the FFI structs/records ([CameraConfig], [PhotoOptions], …), and
/// the generated `nativeValue`/`fromNative` codec extensions.
///
/// Import this only for advanced use: calling the module directly, injecting
/// a fake [NitroCamera] into `OrientationManager`/`CameraDevicesObserver`, or
/// custom bridging. **Stability tracks the generated nitro bridge, not this
/// package's semver** — symbols here can change whenever the spec or the
/// generator changes. Everyday code should only need
/// `package:nitro_camera/nitro_camera.dart`.
library;

export 'src/nitro_camera.native.dart';
