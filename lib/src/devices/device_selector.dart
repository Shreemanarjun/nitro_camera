/// Device selection helpers — the Dart analogue of vision-camera's
/// `getCameraDevice(devices, filter)` (src/devices/getCameraDevice.ts) and the
/// `useCameraDevice(position, filter)` hook.
library;

import '../models/camera_device.dart';

/// Picks the best [CameraDeviceInfo] from [devices], mirroring vision-camera's
/// `getCameraDevice` ranking:
///
///  * a [HardwareLevel.full] device always beats limited/legacy (+4);
///  * unless the caller *explicitly* asks for non-wide-angle physical devices,
///    a device containing the wide-angle lens is preferred (+2 — the sensible
///    default lens);
///  * when [physicalDevices] is given, each matching physical lens scores +1
///    and each extra (unrequested) lens scores −1, so an exact single-lens
///    match beats a do-it-all logical camera, and a logical triple camera wins
///    only when all its lenses were asked for.
///
/// [position] pre-filters by facing — the equivalent of `useCameraDevice`'s
/// positional argument. Returns `null` when no device matches.
CameraDeviceInfo? selectCameraDevice(
  List<CameraDeviceInfo> devices, {
  CameraPosition? position,
  List<PhysicalDeviceType>? physicalDevices,
}) {
  var candidates = devices;
  if (position != null) {
    candidates = devices.where((d) => d.position == position).toList();
  }
  if (candidates.isEmpty) return null;

  final wanted = physicalDevices?.toSet();
  final explicitlyWantsNonWide =
      wanted != null && !wanted.contains(PhysicalDeviceType.wideAngleCamera);

  int score(CameraDeviceInfo d) {
    var points = 0;
    if (d.hardwareLevel == HardwareLevel.full) points += 4;
    if (!explicitlyWantsNonWide &&
        d.physicalDevices.contains(PhysicalDeviceType.wideAngleCamera)) {
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

/// Fluent selection sugar over a device list.
extension CameraDeviceSelection on List<CameraDeviceInfo> {
  /// The best back camera (optionally restricted to [physicalDevices]).
  CameraDeviceInfo? backCamera({List<PhysicalDeviceType>? physicalDevices}) =>
      selectCameraDevice(this,
          position: CameraPosition.back, physicalDevices: physicalDevices);

  /// The best front camera.
  CameraDeviceInfo? frontCamera({List<PhysicalDeviceType>? physicalDevices}) =>
      selectCameraDevice(this,
          position: CameraPosition.front, physicalDevices: physicalDevices);

  /// The best external (USB) camera, if any.
  CameraDeviceInfo? externalCamera() =>
      selectCameraDevice(this, position: CameraPosition.external);
}
