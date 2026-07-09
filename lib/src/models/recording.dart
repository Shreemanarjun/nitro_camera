import '../nitro_camera.native.dart';

/// Why a video recording finished.
///
/// Mirrors vision-camera's `RecordingFinishedReason`.
enum RecordingFinishedReason { stopped, maxDurationReached, maxFileSizeReached }

extension RecordingResultMetadata on RecordingResult {
  RecordingFinishedReason get reason {
    final i = finishedReason;
    if (i < 0 || i >= RecordingFinishedReason.values.length) {
      return RecordingFinishedReason.stopped;
    }
    return RecordingFinishedReason.values[i];
  }

  VideoCodec get videoCodec =>
      codec == VideoCodec.hevc.index ? VideoCodec.hevc : VideoCodec.h264;

  VideoFileType get videoFileType => fileType == VideoFileType.mov.index
      ? VideoFileType.mov
      : VideoFileType.mp4;
}
