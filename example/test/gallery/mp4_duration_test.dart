import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera_example/features/gallery/services/media_services.dart';

/// Builds one ISO-BMFF box: 32-bit size header + type + payload.
Uint8List box(String type, List<int> payload) {
  final b = BytesBuilder();
  b.add(_be32(8 + payload.length));
  b.add(type.codeUnits);
  b.add(payload);
  return b.toBytes();
}

List<int> _be32(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

List<int> _be64(int v) => [..._be32(v >> 32), ..._be32(v & 0xffffffff)];

/// mvhd v0 payload: version+flags, creation, modification, timescale, duration.
List<int> mvhdV0({required int timescale, required int duration}) => [
      ...[0, 0, 0, 0], // version 0 + flags
      ..._be32(0), // creation
      ..._be32(0), // modification
      ..._be32(timescale),
      ..._be32(duration),
    ];

/// mvhd v1 payload: 64-bit creation/modification/duration.
List<int> mvhdV1({required int timescale, required int duration}) => [
      ...[1, 0, 0, 0], // version 1 + flags
      ..._be64(0), // creation
      ..._be64(0), // modification
      ..._be32(timescale),
      ..._be64(duration),
    ];

Future<String> writeTemp(List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('mp4dur');
  final f = File('${dir.path}/clip.mp4');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}

void main() {
  test('reads duration from mvhd v0', () async {
    final bytes = BytesBuilder()
      ..add(box('ftyp', 'isom0000'.codeUnits))
      ..add(box('moov', box('mvhd', mvhdV0(timescale: 600, duration: 3000))));
    final path = await writeTemp(bytes.toBytes());
    expect(await probeMp4Duration(path), const Duration(seconds: 5));
  });

  test('reads duration from mvhd v1', () async {
    final bytes = BytesBuilder()
      ..add(box('ftyp', 'isom0000'.codeUnits))
      ..add(box('moov',
          box('mvhd', mvhdV1(timescale: 1000, duration: 12345))));
    final path = await writeTemp(bytes.toBytes());
    expect(await probeMp4Duration(path),
        const Duration(milliseconds: 12345));
  });

  test('finds moov after a large mdat (non-faststart layout)', () async {
    final bytes = BytesBuilder()
      ..add(box('ftyp', 'isom0000'.codeUnits))
      ..add(box('mdat', List.filled(4096, 0x42)))
      ..add(box('moov', box('mvhd', mvhdV0(timescale: 90000, duration: 90000))));
    final path = await writeTemp(bytes.toBytes());
    expect(await probeMp4Duration(path), const Duration(seconds: 1));
  });

  test('skips sibling boxes inside moov before mvhd', () async {
    final bytes = BytesBuilder()
      ..add(box('moov', [
        ...box('iods', List.filled(8, 0)),
        ...box('mvhd', mvhdV0(timescale: 600, duration: 600)),
      ]));
    final path = await writeTemp(bytes.toBytes());
    expect(await probeMp4Duration(path), const Duration(seconds: 1));
  });

  test('returns null for the v0 unknown-duration sentinel', () async {
    final bytes = BytesBuilder()
      ..add(box('moov',
          box('mvhd', mvhdV0(timescale: 600, duration: 0xFFFFFFFF))));
    final path = await writeTemp(bytes.toBytes());
    expect(await probeMp4Duration(path), isNull);
  });

  test('returns null for garbage / truncated files', () async {
    expect(await probeMp4Duration(await writeTemp([1, 2, 3])), isNull);
    expect(
        await probeMp4Duration(
            await writeTemp(List.filled(64, 0xAB))),
        isNull);
    expect(await probeMp4Duration('/nonexistent/nope.mp4'), isNull);
  });

  test('corrupt zero-advance box cannot loop forever', () async {
    // size=4 (< header length) would never advance the offset.
    final bytes = BytesBuilder()
      ..add(_be32(4))
      ..add('free'.codeUnits)
      ..add(List.filled(32, 0));
    final path = await writeTemp(bytes.toBytes());
    expect(
      await probeMp4Duration(path).timeout(const Duration(seconds: 2)),
      isNull,
    );
  });
}
