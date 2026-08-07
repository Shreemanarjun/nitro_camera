import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Structural facts read out of a recorded MP4's own boxes.
///
/// Every recording assertion in the suite currently consumes the plugin's
/// SELF-REPORTED [RecordingResult] (path / fileSize / durationMs / reason), so
/// a file the plugin believes it wrote correctly passes even when it is
/// unplayable or rotated. Two production defects hide in exactly that blind
/// spot:
///
///  * A recording torn down by the Android lifecycle path never gets its
///    `moov` atom written — the file is non-empty and the reported size is
///    plausible, but no player can open it. [hasMoov] is the only check that
///    fails.
///  * `MediaRecorder.setOrientationHint` is never called, so the persistent
///    input-surface path stores frames in sensor orientation. The bytes are
///    fine; only the `tkhd` transform matrix reveals it. [rotationDegrees].
class Mp4Info {
  /// `ftyp` was present and the major brand parsed.
  final bool hasFtyp;

  /// The media-data box exists and is non-empty (frames actually reached the
  /// encoder).
  final bool hasMdat;

  /// The movie header exists. A recorder killed before `stop()` finalises
  /// leaves this FALSE — the definitive "truncated / unplayable" signal.
  final bool hasMoov;

  /// Duration from `mvhd` (timescale-corrected), or null when absent.
  final int? durationMs;

  /// Number of `trak` boxes.
  final int trackCount;

  /// A `trak` whose `hdlr` handler type is `soun` is present.
  final bool hasAudioTrack;

  /// A `trak` whose `hdlr` handler type is `vide` is present.
  final bool hasVideoTrack;

  /// Display rotation encoded in the video track's `tkhd` transform matrix,
  /// normalised to 0/90/180/270. Null when there is no video `tkhd`.
  ///
  /// This is the SAME convention as `MediaRecorder.setOrientationHint(d)` and
  /// `ffprobe`'s `stream_side_data=rotation`, i.e. the clockwise rotation a
  /// player must apply for correct display. The stored matrix encodes the
  /// inverse of that, so [_readTkhd] negates it — verified against ffmpeg
  /// fixtures built with `-display_rotation {0,90,180,270}`.
  final int? rotationDegrees;

  /// Video track dimensions from `tkhd` (pre-rotation, as stored).
  final int? width;
  final int? height;

  const Mp4Info({
    required this.hasFtyp,
    required this.hasMdat,
    required this.hasMoov,
    required this.durationMs,
    required this.trackCount,
    required this.hasAudioTrack,
    required this.hasVideoTrack,
    required this.rotationDegrees,
    required this.width,
    required this.height,
  });

  /// A file a media player can actually open: container finalised, with media
  /// data and at least one video track.
  bool get isPlayable => hasFtyp && hasMdat && hasMoov && hasVideoTrack;

  @override
  String toString() =>
      'Mp4Info(playable=$isPlayable, ftyp=$hasFtyp, mdat=$hasMdat, '
      'moov=$hasMoov, durationMs=$durationMs, tracks=$trackCount, '
      'video=$hasVideoTrack, audio=$hasAudioTrack, '
      'rotation=$rotationDegrees, ${width}x$height)';
}

/// Reads the box structure of [file] without decoding any media.
///
/// The whole file is read into memory: test clips are a few MB and seeking
/// through `RandomAccessFile` for every box header costs more than it saves.
Mp4Info probeMp4(File file) {
  final bytes = file.readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final state = _ProbeState();
  _walk(bytes, data, 0, bytes.length, state);

  int? durationMs;
  if (state.movieTimescale > 0 && state.movieDuration > 0) {
    durationMs = (state.movieDuration * 1000 / state.movieTimescale).round();
  }

  return Mp4Info(
    hasFtyp: state.hasFtyp,
    hasMdat: state.mdatBytes > 0,
    hasMoov: state.hasMoov,
    durationMs: durationMs,
    trackCount: state.trackCount,
    hasAudioTrack: state.hasAudioTrack,
    hasVideoTrack: state.hasVideoTrack,
    rotationDegrees: state.videoRotation,
    width: state.videoWidth,
    height: state.videoHeight,
  );
}

class _ProbeState {
  bool hasFtyp = false;
  bool hasMoov = false;
  int mdatBytes = 0;
  int trackCount = 0;
  bool hasAudioTrack = false;
  bool hasVideoTrack = false;
  int movieTimescale = 0;
  int movieDuration = 0;

  /// `tkhd` precedes `hdlr` inside a `trak`, so the transform is parked here
  /// and only promoted to the video track once `hdlr` says `vide`.
  int? pendingRotation;
  int? pendingWidth;
  int? pendingHeight;

  int? videoRotation;
  int? videoWidth;
  int? videoHeight;
}

/// Container boxes whose payload is itself a box list.
const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'udta'};

void _walk(Uint8List bytes, ByteData data, int start, int end, _ProbeState s) {
  var offset = start;
  // A truncated file ends mid-box; stop cleanly rather than throwing, because
  // "we could not finish walking" IS the truncation signal the caller wants.
  while (offset + 8 <= end) {
    var size = data.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    var header = 8;

    if (size == 1) {
      if (offset + 16 > end) return;
      size = data.getUint64(offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) return;

    final bodyStart = offset + header;
    final bodyEnd = offset + size;

    switch (type) {
      case 'ftyp':
        s.hasFtyp = true;
      case 'mdat':
        s.mdatBytes += size - header;
      case 'moov':
        s.hasMoov = true;
      case 'trak':
        s.trackCount++;
        s.pendingRotation = null;
        s.pendingWidth = null;
        s.pendingHeight = null;
      case 'mvhd':
        _readMvhd(data, bodyStart, bodyEnd, s);
      case 'tkhd':
        _readTkhd(data, bodyStart, bodyEnd, s);
      case 'hdlr':
        _readHdlr(bytes, bodyStart, bodyEnd, s);
    }

    if (_containers.contains(type)) _walk(bytes, data, bodyStart, bodyEnd, s);
    offset = bodyEnd;
  }
}

void _readMvhd(ByteData d, int start, int end, _ProbeState s) {
  if (start + 4 > end) return;
  final version = d.getUint8(start);
  final p = start + 4; // skip version + flags
  if (version == 1) {
    if (p + 28 > end) return;
    s.movieTimescale = d.getUint32(p + 16);
    s.movieDuration = d.getUint64(p + 20);
  } else {
    if (p + 16 > end) return;
    s.movieTimescale = d.getUint32(p + 8);
    s.movieDuration = d.getUint32(p + 12);
  }
}

void _readTkhd(ByteData d, int start, int end, _ProbeState s) {
  if (start + 4 > end) return;
  final version = d.getUint8(start);
  // version+flags, then creation/modification/trackID/reserved/duration —
  // 8-byte timestamps and duration in v1, 4-byte in v0.
  var p = start + 4 + (version == 1 ? 32 : 20);
  // reserved(8) + layer(2) + altGroup(2) + volume(2) + reserved(2)
  p += 16;
  if (p + 36 + 8 > end) return;

  // 3x3 transform; a,b,c,d are 16.16 fixed point.
  final a = d.getInt32(p) / 65536.0;
  final b = d.getInt32(p + 4) / 65536.0;
  final c = d.getInt32(p + 12) / 65536.0;
  final dd = d.getInt32(p + 16) / 65536.0;
  p += 36;

  final w = d.getUint32(p) >> 16;
  final h = d.getUint32(p + 4) >> 16;

  // An all-zero matrix means "no transform written"; treat it as unrotated
  // rather than reporting a bogus atan2 of (0,0).
  final int rotation;
  if (a == 0 && b == 0 && c == 0 && dd == 0) {
    rotation = 0;
  } else {
    // Negated: atan2(b, a) is the matrix's own rotation, and the matrix maps
    // stored frames -> display, so the rotation a player applies is its
    // inverse. Matches setOrientationHint / ffprobe.
    final deg = -math.atan2(b, a) * 180 / math.pi;
    rotation = ((deg.round() % 360) + 360) % 360;
  }

  s.pendingRotation = rotation;
  s.pendingWidth = w;
  s.pendingHeight = h;
}

void _readHdlr(Uint8List bytes, int start, int end, _ProbeState s) {
  // version(1) flags(3) preDefined(4) handlerType(4)
  final typeAt = start + 8;
  if (typeAt + 4 > end) return;
  final handler = String.fromCharCodes(bytes, typeAt, typeAt + 4);
  if (handler == 'soun') {
    s.hasAudioTrack = true;
  } else if (handler == 'vide') {
    s.hasVideoTrack = true;
    s.videoRotation = s.pendingRotation;
    s.videoWidth = s.pendingWidth;
    s.videoHeight = s.pendingHeight;
  }
}
