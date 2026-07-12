import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

CodeResult _r(String text) => CodeResult(text, CodeFormat.qrCode);

void main() {
  group('ScanConfirmer', () {
    test('requires N consecutive identical frames', () {
      final c = ScanConfirmer(confirmationFrames: 2);
      expect(c.onFrame(_r('A'), nowMs: 0), isNull); // 1st sighting
      expect(c.onFrame(_r('A'), nowMs: 50)?.text, 'A'); // confirmed
    });

    test('a miss resets the streak', () {
      final c = ScanConfirmer(confirmationFrames: 2);
      expect(c.onFrame(_r('A'), nowMs: 0), isNull);
      expect(c.onFrame(null, nowMs: 30), isNull); // miss → reset
      expect(c.onFrame(_r('A'), nowMs: 60), isNull); // back to 1st
      expect(c.onFrame(_r('A'), nowMs: 90), isNotNull);
    });

    test('a different payload resets the streak', () {
      final c = ScanConfirmer(confirmationFrames: 2);
      expect(c.onFrame(_r('A'), nowMs: 0), isNull);
      expect(c.onFrame(_r('B'), nowMs: 30), isNull);
      expect(c.onFrame(_r('B'), nowMs: 60)?.text, 'B');
    });

    test('cooldown suppresses repeats, then allows again', () {
      final c = ScanConfirmer(confirmationFrames: 2, cooldown: const Duration(milliseconds: 1000));
      expect(c.onFrame(_r('A'), nowMs: 0), isNull);
      expect(c.onFrame(_r('A'), nowMs: 30), isNotNull); // emit @30
      // Still confirmed on later frames but inside cooldown:
      expect(c.onFrame(_r('A'), nowMs: 400), isNull);
      expect(c.onFrame(_r('A'), nowMs: 900), isNull);
      // After cooldown:
      expect(c.onFrame(_r('A'), nowMs: 1200), isNotNull);
    });

    test('different payloads have independent cooldowns', () {
      final c = ScanConfirmer(confirmationFrames: 1, cooldown: const Duration(milliseconds: 1000));
      expect(c.onFrame(_r('A'), nowMs: 0), isNotNull);
      expect(c.onFrame(_r('B'), nowMs: 100), isNotNull);
      expect(c.onFrame(_r('A'), nowMs: 200), isNull); // A on cooldown
    });
  });

  group('mapDecodedPointsToWindow', () {
    test('upright pass-through normalizes', () {
      final out = mapDecodedPointsToWindow([50, 25, 100, 75], 200, 100, false);
      expect(out, [0.25, 0.25, 0.5, 0.75]);
    });

    test('rotated points invert the 90° cw rotation', () {
      // Window 200×100. Rotation maps (x,y) → (h-1-y, x) = (99-y, x).
      // Take original point (x=50, y=25): rotated coords (74, 50).
      final out = mapDecodedPointsToWindow([74, 50], 200, 100, true);
      expect(out[0], closeTo(50 / 200, 1e-9));
      expect(out[1], closeTo(25 / 100, 1e-9));
    });

    test('clamps out-of-range points into the unit square', () {
      final out = mapDecodedPointsToWindow([-10, 250], 200, 100, false);
      expect(out[0], 0.0);
      expect(out[1], 1.0);
    });

    test('frameOrientation 90 rotates points cw to the displayed window', () {
      // Sensor-oriented window point at normalized (0.25, 0.1). On screen the
      // buffer is shown rotated 90° cw: (x, y) → (1-y, x).
      final out = mapDecodedPointsToWindow([25, 10], 100, 100, false, frameOrientation: 90);
      expect(out[0], closeTo(0.9, 1e-9));
      expect(out[1], closeTo(0.25, 1e-9));
    });

    test('frameOrientation 270 rotates points ccw', () {
      // (x, y) → (y, 1-x).
      final out = mapDecodedPointsToWindow([25, 10], 100, 100, false, frameOrientation: 270);
      expect(out[0], closeTo(0.1, 1e-9));
      expect(out[1], closeTo(0.75, 1e-9));
    });

    test('mirrored flips horizontally after rotation', () {
      final out = mapDecodedPointsToWindow([25, 10], 100, 100, false, frameOrientation: 90, mirrored: true);
      expect(out[0], closeTo(1 - 0.9, 1e-9));
      expect(out[1], closeTo(0.25, 1e-9));
    });

    test('portrait 1D: rotated pass + sensor 90 keeps a horizontal scanline', () {
      // A horizontal 1D code on a portrait screen is VERTICAL in the sensor
      // buffer, so it decodes via the rotated pass. zxing sees a horizontal
      // scanline in the rotated bitmap: endpoints (10, 50) and (90, 50) in a
      // 100×100 window. After the inverse rotation + the sensor-90 display
      // rotation, the painted line must be horizontal again (same y).
      final out = mapDecodedPointsToWindow([10, 50, 90, 50], 100, 100, true, frameOrientation: 90);
      expect(out[1], closeTo(out[3], 1e-9), reason: 'same screen y');
      expect((out[0] - out[2]).abs(), greaterThan(0.5), reason: 'spans horizontally');
    });
  });
}
