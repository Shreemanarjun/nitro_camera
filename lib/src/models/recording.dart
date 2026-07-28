import '../nitro_camera.native.dart';

/// Why a video recording finished.
///
/// Mirrors vision-camera's `RecordingFinishedReason`. [failed] means the
/// native recorder could not finalise a playable file (e.g. the encoder
/// received no frames, so the MP4 moov atom was never written) — the
/// truncated file is deleted natively and [CameraController.stopRecording]
/// surfaces this as a `RecorderException` instead of returning the result.
enum RecordingFinishedReason { stopped, maxDurationReached, maxFileSizeReached, failed }

extension RecordingResultMetadata on RecordingResult {
  RecordingFinishedReason get reason {
    final i = finishedReason;
    if (i < 0 || i >= RecordingFinishedReason.values.length) {
      return RecordingFinishedReason.stopped;
    }
    return RecordingFinishedReason.values[i];
  }

  /// Whether the native side actually finalised a playable file.
  ///
  /// False when finalisation failed ([RecordingFinishedReason.failed]) or when
  /// there was no active recording to stop (empty [RecordingResult.path]).
  bool get isFinalized => reason != RecordingFinishedReason.failed && path.isNotEmpty;

  VideoCodec get videoCodec => codec == VideoCodec.hevc.index ? VideoCodec.hevc : VideoCodec.h264;

  VideoFileType get videoFileType => fileType == VideoFileType.mov.index ? VideoFileType.mov : VideoFileType.mp4;
}
