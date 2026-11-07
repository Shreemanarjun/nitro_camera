import 'dart:typed_data';

import '../nitro_camera.native.dart' show DepthFrame;

/// What the lens does after `CameraController.focusAt` (vision-camera's
/// `focus(point, { adaptiveness })`).
enum FocusAdaptiveness {
  /// Continuous auto-focus resumes around the point (follows the subject).
  continuous,

  /// Focus stays where the scan ended until the next focus call.
  locked,
}

/// Typed view of a [DepthFrame]'s float32 metres.
extension DepthFrameMetres on DepthFrame {
  /// Row-major distances in metres (0 = no measurement). Borrowed: valid only
  /// inside the stream listener — copy it to keep it.
  Float32List get metres => data.buffer.asFloat32List(data.offsetInBytes, width * height);

  /// Distance at pixel ([x], [y]) in metres.
  double metresAt(int x, int y) {
    RangeError.checkValueInInterval(x, 0, width - 1, 'x');
    RangeError.checkValueInInterval(y, 0, height - 1, 'y');
    return ByteData.sublistView(data).getFloat32(y * bytesPerRow + x * 4, Endian.little);
  }
}
