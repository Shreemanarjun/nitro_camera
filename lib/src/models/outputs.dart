import 'dart:typed_data';

import '../nitro_camera.native.dart' show DepthFrame, ResizedFrame, SyncedFrame;

/// What the lens does after `CameraController.focusAt` (vision-camera's
/// `focus(point, { adaptiveness })`).
enum FocusAdaptiveness {
  /// Continuous auto-focus resumes around the point (follows the subject).
  continuous,

  /// Focus stays where the scan ended until the next focus call.
  locked,
}

/// Channel layout of a GPU-resizer tensor ([CameraController.startResizer]).
enum TensorLayout {
  rgb(3, 0),
  rgba(4, 0),
  bgr(3, 1),
  bgra(4, 1);

  const TensorLayout(this.channels, this.wireOrder);

  /// Values per pixel.
  final int channels;

  /// Native channel-order code (0 = RGB(A), 1 = BGR(A)).
  final int wireOrder;
}

/// Value type of a GPU-resizer tensor.
enum TensorDataType {
  /// 0..255 bytes.
  uint8,

  /// 0..1 floats.
  float32,
}

/// How a frame is fitted into the tensor size.
enum ResizeFit {
  /// Scale to fill, cropping the overflow.
  cover,

  /// Scale to fit, padding with black bars.
  contain,
}

/// Typed views of a [ResizedFrame] tensor.
extension ResizedFrameTensor on ResizedFrame {
  /// The tensor's value type.
  TensorDataType get type => dataType == 1 ? TensorDataType.float32 : TensorDataType.uint8;

  /// The tensor as float32 values (0..1) — only for [TensorDataType.float32].
  /// Borrowed: valid only inside the stream listener.
  Float32List get float32 => data.buffer.asFloat32List(data.offsetInBytes, width * height * channels);

  /// The tensor as uint8 values (0..255) — only for [TensorDataType.uint8].
  Uint8List get uint8 => data.buffer.asUint8List(data.offsetInBytes, width * height * channels);
}

/// Typed view of a [SyncedFrame]'s depth map (float32 metres, like
/// [DepthFrameMetres]).
extension SyncedFrameMetres on SyncedFrame {
  /// Row-major distances in metres (0 = no measurement). Borrowed: valid only
  /// inside the stream listener — copy it to keep it.
  Float32List get metres => depth.buffer.asFloat32List(depth.offsetInBytes, depthWidth * depthHeight);

  /// Distance at depth-map pixel ([x], [y]), in metres.
  double metresAt(int x, int y) => metres[y * depthWidth + x];
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
