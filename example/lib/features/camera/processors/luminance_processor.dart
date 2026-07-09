import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'frame_processor.dart';

/// Reference [FrameProcessor] implementation: estimates the mean scene
/// luminance of every sampled frame and publishes it as a reactive signal
/// (0.0 = black, 1.0 = white) that the UI renders live.
///
/// It demonstrates the full custom-processor recipe:
///  * sparse pixel sampling so the synchronous callback stays ~free;
///  * honouring the zero-copy contract (pixels are only read inside
///    [processFrame], nothing is retained);
///  * handling both YUV (plane 0 = luma) and BGRA frames;
///  * pushing results out through app state (a signal) instead of holding
///    them in the processor.
///
/// Copy this shape for your own pipeline (custom ML model, OpenCV, etc.).
class LuminanceFrameProcessor implements FrameProcessor {
  /// Mean luminance of the last processed frame, 0..1.
  final luminance = signal(0.0);

  /// Frames processed since the last attach. This is the DELIVERY signal —
  /// luminance can legitimately be 0.0 (covered lens / black scene), so
  /// "are frames flowing?" must be answered by this counter, not the value.
  final framesProcessed = signal(0);

  /// Whether the processor is currently attached to a live session.
  final attached = signal(false);

  /// How many pixels to sample per frame (sparse stride sampling).
  static const int _kSamples = 256;

  @override
  String get name => 'LUMA';

  @override
  void onAttach(CameraController controller) {
    attached.value = true;
  }

  @override
  void processFrame(CameraFrame frame) {
    framesProcessed.value++;
    final px = frame.pixels;
    if (px.isEmpty) return;

    final isYuv = frame.pixelFormat == 0;
    // YUV plane 0 is straight luma — sample single bytes. BGRA approximates
    // luma from the green channel (offset 1), close enough for a meter.
    final stride = isYuv ? 1 : 4;
    final offset = isYuv ? 0 : 1;
    final usable = px.length - offset;
    if (usable <= 0) return;

    final count = usable ~/ stride < _kSamples ? usable ~/ stride : _kSamples;
    if (count == 0) return;
    final step = (usable ~/ count) ~/ stride * stride;
    final hop = step == 0 ? stride : step;

    var sum = 0;
    var n = 0;
    for (var i = offset; i < px.length && n < count; i += hop) {
      sum += px[i];
      n++;
    }
    if (n == 0) return;
    luminance.value = sum / n / 255.0;
  }

  @override
  void onDetach() {
    attached.value = false;
    luminance.value = 0.0;
    framesProcessed.value = 0;
  }
}

/// App-wide demo instance (toggled by the PROC chip in the top bar).
final luminanceProcessor = LuminanceFrameProcessor();
