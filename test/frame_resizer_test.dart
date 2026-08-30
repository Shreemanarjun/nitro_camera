import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

void main() {
  test('luma (YUV) downscale halves dims and samples nearest pixels', () {
    // 4×4 luma ramp: value = y*10 + x.
    final b = Uint8List(16);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        b[y * 4 + x] = y * 10 + x;
      }
    }
    final f = FrameData(bytes: b, width: 4, height: 4, format: 0, bytesPerRow: 4);
    final r = f.resized(2, 2);

    expect(r.width, 2);
    expect(r.height, 2);
    expect(r.format, 0);
    expect(r.bytesPerRow, 2); // tightly packed
    // Nearest-neighbour: dest (x,y) -> src (x*4~/2, y*4~/2) = (0/2,0/2),(2,0),(0,2),(2,2)
    expect(r.bytes, [0, 2, 20, 22]);
  });

  test('BGRA (4bpp) resize keeps channels intact', () {
    // 2×1 BGRA: pixel0 = 1,2,3,4  pixel1 = 5,6,7,8.
    final b = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final f = FrameData(bytes: b, width: 2, height: 1, format: 1, bytesPerRow: 8);
    final up = f.resized(4, 1); // upscale x2
    expect(up.width, 4);
    expect(up.bytesPerRow, 16);
    // dest x -> src x*2~/4: 0,0,1,1 -> pixels [p0,p0,p1,p1]
    expect(up.bytes, [1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8, 5, 6, 7, 8]);
  });

  test('handles padded source stride (bytesPerRow > width)', () {
    // 2×4 luma with 1 pad byte per row (stride 3); downscale 4→2 rows.
    final b = Uint8List.fromList([
      10, 20, 99, // row0
      30, 40, 99, // row1
      50, 60, 99, // row2
      70, 80, 99, // row3
    ]);
    final f = FrameData(bytes: b, width: 2, height: 4, format: 0, bytesPerRow: 3);
    final r = f.resized(2, 2);
    // dest rows map to src rows 0 and 2; padding (99) never sampled.
    expect(r.bytes, [10, 20, 50, 60]);
    expect(r.bytesPerRow, 2);
  });

  test('same-size or non-positive target returns the frame unchanged', () {
    final f = FrameData(
      bytes: Uint8List(4),
      width: 2,
      height: 2,
      format: 0,
      bytesPerRow: 2,
    );
    expect(identical(f.resized(2, 2), f), isTrue);
    expect(identical(f.resized(0, 5), f), isTrue);
  });

  test('resizedToMaxEdge preserves aspect and caps the long edge', () {
    final f = FrameData(
      bytes: Uint8List(1920 * 1080),
      width: 1920,
      height: 1080,
      format: 0,
      bytesPerRow: 1920,
    );
    final r = f.resizedToMaxEdge(640);
    expect(r.width, 640);
    expect(r.height, 360); // 1080 * 640/1920, aspect preserved
    // Already within bounds -> unchanged.
    expect(identical(f.resizedToMaxEdge(4000), f), isTrue);
  });

  test('cropped extracts a sub-rectangle, tightly packed', () {
    // 3×3 luma: value = y*10 + x.
    final b = Uint8List(9);
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 3; x++) {
        b[y * 3 + x] = y * 10 + x;
      }
    }
    final f = FrameData(bytes: b, width: 3, height: 3, format: 0, bytesPerRow: 3);
    final c = f.cropped(1, 1, 2, 2); // bottom-right 2×2
    expect(c.width, 2);
    expect(c.height, 2);
    expect(c.bytesPerRow, 2);
    expect(c.bytes, [11, 12, 21, 22]);
    // Out-of-bounds crop is clamped.
    final c2 = f.cropped(2, 2, 5, 5);
    expect(c2.width, 1);
    expect(c2.height, 1);
    expect(c2.bytes, [22]);
  });

  test('rotated 90/180/270 moves pixels and swaps dims for quarter turns', () {
    // 2×3 luma (w=2, h=3): rows [1,2],[3,4],[5,6].
    final f = FrameData(
      bytes: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      width: 2,
      height: 3,
      format: 0,
      bytesPerRow: 2,
    );
    // 90° CW -> 3×2: top row is the old left column bottom-up [5,3,1], etc.
    final r90 = f.rotated(1);
    expect(r90.width, 3);
    expect(r90.height, 2);
    expect(r90.bytes, [5, 3, 1, 6, 4, 2]);
    // 180° -> 2×3 reversed.
    final r180 = f.rotated(2);
    expect(r180.width, 2);
    expect(r180.height, 3);
    expect(r180.bytes, [6, 5, 4, 3, 2, 1]);
    // 270° CW == inverse of 90.
    final r270 = f.rotated(3);
    expect(r270.width, 3);
    expect(r270.height, 2);
    expect(r270.bytes, [2, 4, 6, 1, 3, 5]);
    // 0 / multiples of 4 are no-ops.
    expect(identical(f.rotated(0), f), isTrue);
    expect(identical(f.rotated(4), f), isTrue);
  });

}

