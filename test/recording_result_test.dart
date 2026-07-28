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

  test('finishedReason 3 decodes to failed and is not finalized', () {
    // Android returns this wire shape when MediaRecorder.stop() throws (the
    // moov atom was never written): empty path, zero sizes, reason = failed.
    const result = RecordingResult(
      path: '',
      durationMs: 0,
      fileSize: 0,
      finishedReason: 3,
    );

    expect(result.reason, RecordingFinishedReason.failed);
    expect(result.isFinalized, isFalse);
  });

  test('isFinalized requires a path and a non-failed reason', () {
    const ok = RecordingResult(
      path: '/tmp/video.mp4',
      durationMs: 1000,
      fileSize: 4096,
      finishedReason: 0,
    );
    expect(ok.isFinalized, isTrue);

    // "No active recorder to stop" — empty path with a benign reason.
    const noneActive = RecordingResult(
      path: '',
      durationMs: 0,
      fileSize: 0,
      finishedReason: 0,
    );
    expect(noneActive.isFinalized, isFalse);

    // A failed finalize is never valid even if a path leaked through.
    const failedWithPath = RecordingResult(
      path: '/tmp/video.mp4',
      durationMs: 0,
      fileSize: 100,
      finishedReason: 3,
    );
    expect(failedWithPath.isFinalized, isFalse);
  });
}
