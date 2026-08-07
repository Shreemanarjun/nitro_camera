import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../patrol_test/support/mp4_probe.dart';

/// Guards `probeMp4` — the only thing in the suite that can tell a finalised
/// recording from a truncated one, or an upright video from a sideways one.
///
/// Every combination recording test asserts on this parser, so a silent
/// regression here would turn the whole recording suite green against broken
/// output. Fixtures are generated with ffmpeg so the assertions run against
/// REAL container bytes with independently-known ground truth (`ffprobe
/// -show_entries stream_side_data=rotation`), not against hand-rolled boxes
/// that would only re-assert the parser's own assumptions.
void main() {
  late Directory tmp;
  var ffmpeg = true;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('mp4probe');
    if (Process.runSync('sh', ['-c', 'command -v ffmpeg']).exitCode != 0) {
      ffmpeg = false;
      return;
    }

    void run(String args) {
      final r = Process.runSync('sh', ['-c', 'cd ${tmp.path} && ffmpeg $args']);
      if (r.exitCode != 0) throw StateError('ffmpeg failed: ${r.stderr}');
    }

    run(
      '-v error -f lavfi -i testsrc=size=640x480:rate=30:duration=2 '
      '-c:v libx264 -pix_fmt yuv420p rot0.mp4 -y',
    );
    for (final rot in [90, 180, 270]) {
      run('-v error -display_rotation $rot -i rot0.mp4 -c copy rot$rot.mp4 -y');
    }
    run(
      '-v error -f lavfi -i testsrc=size=640x480:rate=30:duration=2 '
      '-f lavfi -i sine=frequency=440:duration=2 '
      '-c:v libx264 -c:a aac -pix_fmt yuv420p withaudio.mp4 -y',
    );

    // ffmpeg writes moov last, so half a file is exactly the shape a recorder
    // killed before finalising leaves behind.
    final whole = File('${tmp.path}/rot0.mp4').readAsBytesSync();
    File(
      '${tmp.path}/truncated.mp4',
    ).writeAsBytesSync(whole.sublist(0, whole.length ~/ 2));
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Mp4Info probe(String name) => probeMp4(File('${tmp.path}/$name.mp4'));

  test('reports a finalised clip as playable', () {
    if (!ffmpeg) return;
    final info = probe('rot0');
    expect(info.isPlayable, isTrue);
    expect(info.hasFtyp, isTrue);
    expect(info.hasMdat, isTrue);
    expect(info.hasMoov, isTrue);
    expect(info.hasVideoTrack, isTrue);
    expect(info.width, 640);
    expect(info.height, 480);
    expect(info.durationMs, closeTo(2000, 100));
  });

  test('reports a recorder-killed clip as unplayable', () {
    if (!ffmpeg) return;
    final info = probe('truncated');
    // The exact signature of CameraSession.onAppStop tearing down the camera
    // without stopping MediaRecorder: bytes on disk, no movie header.
    expect(info.hasFtyp, isTrue);
    expect(info.hasMoov, isFalse);
    expect(info.isPlayable, isFalse);
    expect(info.durationMs, isNull);
  });

  test('reads rotation clockwise, as setOrientationHint writes it', () {
    if (!ffmpeg) return;
    // ffmpeg's `-display_rotation` and ffprobe's `stream_side_data=rotation`
    // are COUNTER-clockwise; `MediaRecorder.setOrientationHint` and this parser
    // are clockwise. So a fixture built with `-display_rotation 90` carries a
    // matrix a player rotates 270° clockwise, and vice versa.
    //
    // ffprobe ground truth (CCW) -> expected probeMp4 (CW):
    //     0   -> 0        90 -> 270
    //  -180   -> 180     -90 -> 90
    expect(probe('rot0').rotationDegrees, 0);
    expect(probe('rot90').rotationDegrees, 270);
    expect(probe('rot180').rotationDegrees, 180);
    expect(probe('rot270').rotationDegrees, 90);
  });

  test('distinguishes muxed audio from video-only', () {
    if (!ffmpeg) return;
    final withAudio = probe('withaudio');
    expect(withAudio.hasAudioTrack, isTrue);
    expect(withAudio.hasVideoTrack, isTrue);
    expect(withAudio.trackCount, 2);

    final videoOnly = probe('rot0');
    expect(videoOnly.hasAudioTrack, isFalse);
    expect(videoOnly.trackCount, 1);
  });

  test('does not throw on a non-MP4 file', () {
    final junk = File('${tmp.path}/junk.mp4')
      ..writeAsBytesSync(List<int>.filled(512, 0x41));
    final info = probeMp4(junk);
    expect(info.isPlayable, isFalse);
    expect(info.hasMoov, isFalse);
  });
}
