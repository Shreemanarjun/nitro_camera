import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// Gap-closing tests for [scanFrameAdaptive] — the streaming ladder used by
/// the [CodeScanner] worker: last-hit replay, the escalation to the thorough
/// level, and the miss counter that eventually drops the cache.
///
/// The ladder's state lives in library globals, so these tests are ORDER
/// DEPENDENT by design and live in a file of their own (each `flutter test`
/// file gets its own isolate, so no other test can perturb them).

const _side = 800;

/// A [_side]×[_side] luma plane with a [qrSide]-px QR centred in it, so the
/// scanner's 0.72 viewfinder window contains the whole symbol.
FrameData _qrFrame(String text, {int qrSide = 400}) {
  final matrix = QRCodeWriter().encode(text, BarcodeFormat.qrCode, qrSide, qrSide);
  final bytes = Uint8List.fromList(List.filled(_side * _side, 255));
  final off = (_side - qrSide) ~/ 2;
  for (var y = 0; y < qrSide; y++) {
    for (var x = 0; x < qrSide; x++) {
      if (matrix.get(x, y)) bytes[(y + off) * _side + x + off] = 0;
    }
  }
  return FrameData(bytes: bytes, width: _side, height: _side, format: 0, bytesPerRow: _side);
}

FrameData _blankFrame() => FrameData(
  bytes: Uint8List.fromList(List.filled(_side * _side, 200)),
  width: _side,
  height: _side,
  format: 0,
  bytesPerRow: _side,
);

void main() {
  // 576-px window -> fast level A = 1/2 scale, thorough level B = full scale.
  test('1. a miss escalates to the thorough ladder level', () {
    final blank = _blankFrame();
    // Two frames guarantees one even frame index, which is when level B runs.
    expect(scanFrameAdaptive(blank, CodeScanKind.qr), isNull);
    expect(scanFrameAdaptive(blank, CodeScanKind.qr), isNull);
  });

  test('2. a degenerate zero-sized frame clamps the ladder factor to 1', () {
    final empty = FrameData(bytes: Uint8List(0), width: 0, height: 0, format: 0);
    expect(scanFrameAdaptive(empty, CodeScanKind.postal), isNull);
  });

  test('3. a hit is returned and caches the format for replay', () {
    final r = scanFrameAdaptive(_qrFrame('adaptive-hit'), CodeScanKind.qr);
    expect(r, isNotNull);
    expect(r!.text, 'adaptive-hit');
    expect(r.format, CodeFormat.qrCode);
  });

  test('4. the cached last hit is replayed on the next frame', () {
    // Same payload again: this frame is served by the last-hit replay pass
    // (exact level + orientation + format), not the full ladder.
    final r = scanFrameAdaptive(_qrFrame('adaptive-hit'), CodeScanKind.qr);
    expect(r, isNotNull);
    expect(r!.text, 'adaptive-hit');
  });

  test('5. a different payload still decodes and re-caches', () {
    final r = scanFrameAdaptive(_qrFrame('second-payload'), CodeScanKind.qr);
    expect(r?.text, 'second-payload');
  });

  test('6. the replay is skipped when the kind no longer scans that format', () {
    // The cache holds a QR, but the postal kind never looks for one.
    expect(scanFrameAdaptive(_qrFrame('second-payload'), CodeScanKind.postal), isNull);
  });

  test('7. six consecutive misses drop the cached format, and a later hit still works', () {
    final blank = _blankFrame();
    for (var i = 0; i < 6; i++) {
      expect(scanFrameAdaptive(blank, CodeScanKind.qr), isNull, reason: 'miss #$i');
    }
    // Cache dropped — the full ladder must still find a fresh code.
    expect(scanFrameAdaptive(_qrFrame('after-eviction'), CodeScanKind.qr)?.text, 'after-eviction');
  });

  test('8. timestamp and mirroring metadata are carried onto the result', () {
    final base = _qrFrame('with-metadata');
    final f = FrameData(
      bytes: base.bytes,
      width: base.width,
      height: base.height,
      format: 0,
      bytesPerRow: base.bytesPerRow,
      timestamp: 987654,
      orientation: 90,
      isMirrored: true,
    );
    final r = scanFrameAdaptive(f, CodeScanKind.qr);
    expect(r, isNotNull);
    expect(r!.timestamp, 987654);
    for (final v in r.windowPoints ?? const <double>[]) {
      expect(v, inInclusiveRange(0.0, 1.0));
    }
  });
}
