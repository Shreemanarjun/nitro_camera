/// Wraps the zxing `MultiFormatReader` for the linear + 2D + GS1 DataBar
/// formats ([CodeFormat.isZxing]), including GS1 detection via the symbology
/// identifier metadata.
library;

import 'dart:typed_data';

import 'package:zxing_lib/common.dart' as zxing;
import 'package:zxing_lib/zxing.dart' as zxing;

import '../types.dart';

zxing.BarcodeFormat? _toZxing(CodeFormat f) => switch (f) {
      CodeFormat.qrCode => zxing.BarcodeFormat.qrCode,
      CodeFormat.dataMatrix => zxing.BarcodeFormat.dataMatrix,
      CodeFormat.aztec => zxing.BarcodeFormat.aztec,
      CodeFormat.pdf417 => zxing.BarcodeFormat.pdf417,
      CodeFormat.maxicode => zxing.BarcodeFormat.maxicode,
      CodeFormat.ean13 => zxing.BarcodeFormat.ean13,
      CodeFormat.ean8 => zxing.BarcodeFormat.ean8,
      CodeFormat.upcA => zxing.BarcodeFormat.upcA,
      CodeFormat.upcE => zxing.BarcodeFormat.upcE,
      CodeFormat.code39 => zxing.BarcodeFormat.code39,
      CodeFormat.code93 => zxing.BarcodeFormat.code93,
      CodeFormat.code128 => zxing.BarcodeFormat.code128,
      CodeFormat.itf => zxing.BarcodeFormat.itf,
      CodeFormat.codabar => zxing.BarcodeFormat.codabar,
      CodeFormat.rss14 => zxing.BarcodeFormat.rss14,
      CodeFormat.rssExpanded => zxing.BarcodeFormat.rssExpanded,
      _ => null,
    };

CodeFormat? _fromZxing(zxing.BarcodeFormat f) {
  for (final v in CodeFormat.values) {
    if (_toZxing(v) == f) return v;
  }
  return null;
}

/// Symbology identifiers that mark GS1-structured payloads.
const _gs1SymbologyIds = {']C1', ']e0', ']e1', ']e2', ']d2', ']Q3'};

/// Decodes the window `[left,top]..(left+width, top+height)` of a strided
/// luma plane with zxing, restricted to [formats]. Returns null on no match.
RawDecode? zxingDecode(
  Uint8List luma, {
  required int stride,
  required int left,
  required int top,
  required int width,
  required int height,
  required Set<CodeFormat> formats,
}) {
  final zxFormats =
      formats.map(_toZxing).whereType<zxing.BarcodeFormat>().toList();
  if (zxFormats.isEmpty) return null;
  try {
    final source = _StridedLuminanceSource(
      luma,
      width,
      height,
      stride,
      left: left,
      top: top,
    );
    final bitmap = zxing.BinaryBitmap(zxing.HybridBinarizer(source));
    final result = zxing.MultiFormatReader().decode(
      bitmap,
      zxing.DecodeHint(
        possibleFormats: zxFormats,
        // Screens/print in poor light are often inverted-friendly.
        alsoInverted: true,
      ),
    );
    final format = _fromZxing(result.barcodeFormat);
    if (format == null) return null;
    final symbologyId = result
        .resultMetadata?[zxing.ResultMetadataType.symbologyIdentifier]
        ?.toString();
    final isGs1 = format == CodeFormat.rss14 ||
        format == CodeFormat.rssExpanded ||
        (symbologyId != null && _gs1SymbologyIds.contains(symbologyId));
    return RawDecode(result.text, format, isGs1: isGs1);
  } catch (_) {
    return null; // MultiFormatReader throws NotFoundException on no match.
  }
}

/// [zxing.LuminanceSource] that reads a luma plane with an arbitrary **row
/// stride** (the camera's `bytesPerRow`) and an optional **window offset**
/// ([left], [top]) — a zero-copy cropped view over the full plane.
class _StridedLuminanceSource extends zxing.LuminanceSource {
  final Uint8List _pixels;
  final int _stride;
  final int _left;
  final int _top;

  _StridedLuminanceSource(
    this._pixels,
    int width,
    int height,
    this._stride, {
    int left = 0,
    int top = 0,
  })  : _left = left,
        _top = top,
        super(width, height);

  @override
  Uint8List getRow(int y, Uint8List? row) {
    final res = (row != null && row.length >= width) ? row : Uint8List(width);
    final start = (y + _top) * _stride + _left;
    final end = start + width;
    if (end <= _pixels.length) {
      res.setRange(0, width, _pixels, start);
    }
    return res;
  }

  @override
  Uint8List get matrix {
    if (_stride == width && _left == 0 && _top == 0) return _pixels;
    final m = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      final src = (y + _top) * _stride + _left;
      if (src + width > _pixels.length) break;
      m.setRange(y * width, y * width + width, _pixels, src);
    }
    return m;
  }

  @override
  bool get isCropSupported => false;
}
