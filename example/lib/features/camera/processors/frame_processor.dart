import 'package:nitro_camera/nitro_camera.dart';

/// Contract for a user-supplied camera frame processor.
///
/// Instead of baking detection into the native side (ML Kit et al.), the app
/// exposes this small interface: implement it with whatever pipeline you like
/// (your own ML model, OpenCV bindings, a pure-Dart analyzer, an isolate
/// hand-off...) and plug it in with `cameraStore.setFrameProcessor(...)`.
/// The store owns all the session plumbing — enabling native frame delivery,
/// (re)attaching across camera switches, and routing every delivered frame to
/// [processFrame].
///
/// Contract:
///  * [processFrame] is called synchronously on the frame-stream listener.
///    `frame.pixels` is a ZERO-COPY view into the native camera buffer — read
///    what you need inside the call and never hold a reference to it past the
///    return. Copy (`Uint8List.fromList`) if you must defer work.
///  * Keep [processFrame] cheap; heavy work belongs on an isolate (see the
///    plugin's `CodeScanner` for a drop-latest hand-off pattern). Frame
///    cadence is tuned with `cameraStore.setSamplingRate` (the ANALYZE pill).
///  * `frame_processor_helpers.dart` ships vision-camera-style combinators:
///    `TargetFpsProcessor` (= runAtTargetFps), `AsyncFrameProcessor`
///    (= runAsync: copy synchronously, process async, drop while busy) and
///    `CompositeFrameProcessor` (several consumers on one stream).
///  * `frame.pixelFormat` is 0 (YUV_420 — plane 0 is luma) or 1 (BGRA_8888);
///    SCANNER mode switches the stream to YUV, so handle both.
///  * [onAttach] runs when a live session adopts the processor — once when
///    set on a running camera, and again after every camera/format switch
///    (each reopen is a brand-new native session). [onDetach] runs when the
///    processor is replaced or cleared.
abstract class FrameProcessor {
  /// Short display name (badges, tooltips, debug logs).
  String get name;

  /// A live session adopted this processor. May be called once per session
  /// reopen; use it to reset per-session state or to grab session facts
  /// (resolution, fps) from [controller].
  void onAttach(CameraController controller) {}

  /// One delivered camera frame. Synchronous — see the class contract.
  void processFrame(CameraFrame frame);

  /// The processor was replaced or cleared — release per-run state here.
  void onDetach() {}
}
