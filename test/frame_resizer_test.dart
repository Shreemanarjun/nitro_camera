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
}
