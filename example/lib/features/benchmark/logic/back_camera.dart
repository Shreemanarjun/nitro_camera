import 'package:nitro_camera/native.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Camera permission (1 = granted, see PermissionStatus) + best back camera.
/// Returns null with a reason when either is unavailable.
Future<(CameraDeviceInfo?, String)> acquireBackCamera() async {
  final nc = NitroCamera.instance;
  if (nc.getCameraPermissionStatus() != 1 &&
      await nc.requestCameraPermission() != 1) {
    return (null, 'Camera permission denied');
  }
  final devices = await CameraController.getAvailableCameraDevices();
  final device = devices.backCamera() ?? devices.firstOrNull;
  return (device, device == null ? 'No camera found' : '');
}
