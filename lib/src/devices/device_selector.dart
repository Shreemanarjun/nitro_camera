/// Device selection helpers — the Dart analogue of vision-camera's
/// `getCameraDevice(devices, filter)` (src/devices/getCameraDevice.ts) and the
/// `useCameraDevice(position, filter)` hook.
library;

import '../models/camera_device.dart';

/// The physical lens types backing a (possibly logical) camera device.
/// String values match vision-camera's `PhysicalCameraDeviceType`.
enum PhysicalDeviceType {
  ultraWideAngleCamera('ultra-wide-angle-camera'),
  wideAngleCamera('wide-angle-camera'),
  telephotoCamera('telephoto-camera');

  final String value;
  const PhysicalDeviceType(this.value);
}

/// Picks the best [CameraDeviceInfo] from [devices], mirroring vision-camera's
/// `getCameraDevice` ranking:
///
///  * a `full` hardware level always beats `limited`/`legacy` (+4);
///  * unless the caller *explicitly* asks for non-wide-angle physical devices,
///    a device containing the wide-angle lens is preferred (+2 — the sensible
///    default lens);
///  * when [physicalDevices] is given, each matching physical lens scores +1
///    and each extra (unrequested) lens scores −1, so an exact single-lens
///    match beats a do-it-all logical camera, and a logical triple camera wins
///    only when all its lenses were asked for.
///
/// [position] pre-filters by facing (a [CameraDeviceInfo.position] value:
/// 0 front / 1 back / 2 external) — the equivalent of `useCameraDevice`'s
/// positional argument. Returns `null` when no device matches.
CameraDeviceInfo? selectCameraDevice(
  List<CameraDeviceInfo> devices, {
  int? position,
  List<PhysicalDeviceType>? physicalDevices,
}) {
  var candidates = devices;
  if (position != null) {
    candidates = devices.where((d) => d.position == position).toList();
  }
  if (candidates.isEmpty) return null;

  final wanted = physicalDevices?.map((t) => t.value).toSet();
  final explicitlyWantsNonWide = wanted != null &&
      !wanted.contains(PhysicalDeviceType.wideAngleCamera.value);

  int score(CameraDeviceInfo d) {
    var points = 0;
    if (d.hardwareLevel == 'full') points += 4;
    if (!explicitlyWantsNonWide &&
        d.physicalDevices
            .contains(PhysicalDeviceType.wideAngleCamera.value)) {
      points += 2;
    }
    if (wanted != null) {
      for (final lens in d.physicalDevices) {
        points += wanted.contains(lens) ? 1 : -1;
      }
    }
    return points;
  }

  // reduce keeps the FIRST device on ties (rightPoints must strictly exceed
  // leftPoints to win) — same as vision-camera, so enumeration order is the
  // final tiebreaker.
  return candidates.reduce((best, d) => score(d) > score(best) ? d : best);
}

/// Position filters for [CameraDeviceSelection] (`useCameraDevice`'s first
/// argument). Values match [CameraDeviceInfo.position].
abstract final class DevicePosition {
  static const int front = 0;
  static const int back = 1;
  static const int external = 2;
}

/// Fluent selection sugar over a device list.
extension CameraDeviceSelection on List<CameraDeviceInfo> {
  /// The best back camera (optionally restricted to [physicalDevices]).
  CameraDeviceInfo? backCamera({List<PhysicalDeviceType>? physicalDevices}) =>
      selectCameraDevice(this,
          position: DevicePosition.back, physicalDevices: physicalDevices);

  /// The best front camera.
  CameraDeviceInfo? frontCamera({List<PhysicalDeviceType>? physicalDevices}) =>
      selectCameraDevice(this,
          position: DevicePosition.front, physicalDevices: physicalDevices);

  /// The best external (USB) camera, if any.
  CameraDeviceInfo? externalCamera() =>
      selectCameraDevice(this, position: DevicePosition.external);
}
