import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _AHardwareBufferDesc extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int layers;
  @Uint32()
  external int format;
  @Uint64()
  external int usage;
  @Uint32()
  external int stride;
  @Uint32()
  external int rfu0;
  @Uint64()
  external int rfu1;
}

/// Asks the PLATFORM what a `CameraFrame.nativeBuffer` handle is — proof the
/// pointer is a live AHardwareBuffer / CVPixelBuffer, not just a number.
/// Returns (width, height).
(int, int) describeNativeBuffer(int handle) {
  final ptr = Pointer<Void>.fromAddress(handle);
  if (Platform.isAndroid) {
    final describe = DynamicLibrary.open('libandroid.so')
        .lookupFunction<Void Function(Pointer<Void>, Pointer<_AHardwareBufferDesc>), void Function(Pointer<Void>, Pointer<_AHardwareBufferDesc>)>('AHardwareBuffer_describe');
    final desc = calloc<_AHardwareBufferDesc>();
    try {
      describe(ptr, desc);
      return (desc.ref.width, desc.ref.height);
    } finally {
      calloc.free(desc);
    }
  }
  final lib = DynamicLibrary.process();
  final w = lib.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('CVPixelBufferGetWidth');
  final h = lib.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('CVPixelBufferGetHeight');
  return (w(ptr), h(ptr));
}
