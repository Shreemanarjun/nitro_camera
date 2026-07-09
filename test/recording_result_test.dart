import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

void main() {
  test('RecordingResult exposes typed recording metadata', () {
    const result = RecordingResult(
      path: '/tmp/video.mov',
      durationMs: 1234,
      fileSize: 5678,
      width: 1920,
      height: 1080,
      codec: 1,
      fileType: 1,
      finishedReason: 2,
    );

    expect(result.width, 1920);
    expect(result.height, 1080);
    expect(result.videoCodec, VideoCodec.hevc);
    expect(result.videoFileType, VideoFileType.mov);
    expect(result.reason, RecordingFinishedReason.maxFileSizeReached);
  });

  test('RecordingResult helpers default unknown values conservatively', () {
    const result = RecordingResult(
      path: '/tmp/video.mp4',
      durationMs: 1,
      fileSize: 1,
      codec: 99,
      fileType: 99,
      finishedReason: 99,
    );

    expect(result.videoCodec, VideoCodec.h264);
    expect(result.videoFileType, VideoFileType.mp4);
    expect(result.reason, RecordingFinishedReason.stopped);
  });
}
