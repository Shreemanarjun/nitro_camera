import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/src/scanner/types.dart';

/// Gap-closing tests for the scanner's public value types: symbology
/// classification, kind → format routing, labels and [CodeResult] accessors.

void main() {
  group('CodeFormat classification', () {
    test('the four families partition the enum', () {
      for (final f in CodeFormat.values) {
        final families = [f.is1D, f.is2D, f.isPostal].where((x) => x).length;
        expect(families, 1, reason: '$f must belong to exactly one of 1D/2D/postal');
      }
    });

    test('is1D is the complement of 2D and postal', () {
      expect(CodeFormat.code128.is1D, isTrue);
      expect(CodeFormat.ean13.is1D, isTrue);
      expect(CodeFormat.pharmacode.is1D, isTrue);
      expect(CodeFormat.qrCode.is1D, isFalse);
      expect(CodeFormat.pdf417.is1D, isFalse);
      expect(CodeFormat.postnet.is1D, isFalse);
      expect(CodeFormat.kix.is1D, isFalse);
    });

    test('isPharma marks exactly the two Pharmacode symbologies', () {
      expect(CodeFormat.values.where((f) => f.isPharma).toSet(), {
        CodeFormat.pharmacode,
        CodeFormat.pharmacodeTwoTrack,
      });
    });

    test('isZxing excludes every built-in-decoder symbology', () {
      const builtIn = {
        CodeFormat.msi,
        CodeFormat.code11,
        CodeFormat.industrial2of5,
        CodeFormat.telepen,
        CodeFormat.pharmacode,
        CodeFormat.pharmacodeTwoTrack,
        CodeFormat.postnet,
        CodeFormat.planet,
        CodeFormat.rm4scc,
        CodeFormat.kix,
      };
      expect(CodeFormat.values.where((f) => !f.isZxing).toSet(), builtIn);
      expect(CodeFormat.qrCode.isZxing, isTrue);
    });
  });

  group('CodeScanKind', () {
    test('formats route each kind to its engine set', () {
      expect(CodeScanKind.qr.formats, {CodeFormat.qrCode});
      expect(CodeScanKind.twoD.formats, CodeFormat.values.where((f) => f.is2D).toSet());
      expect(CodeScanKind.postal.formats, CodeFormat.values.where((f) => f.isPostal).toSet());
      expect(CodeScanKind.pharma.formats, {CodeFormat.pharmacode, CodeFormat.pharmacodeTwoTrack});

      final oneD = CodeScanKind.oneD.formats;
      expect(oneD, isNotEmpty);
      expect(oneD.every((f) => f.is1D && !f.isPharma), isTrue);
      expect(oneD, contains(CodeFormat.msi));
      expect(oneD, isNot(contains(CodeFormat.pharmacode)));

      final all = CodeScanKind.all.formats;
      expect(all.any((f) => f.isPharma), isFalse, reason: 'pharma is explicit-only');
      expect(all, containsAll([CodeFormat.qrCode, CodeFormat.code128, CodeFormat.postnet]));
    });

    test('label is a short display tag per kind', () {
      expect(CodeScanKind.values.map((k) => k.label).toList(), ['QR', '1D', '2D', 'POST', 'RX', 'ALL']);
    });
  });

  group('CodeResult', () {
    test('isbn is only reported for Bookland EAN-13 payloads', () {
      expect(const CodeResult('9781234567897', CodeFormat.ean13).isbn, '9781234567897');
      expect(const CodeResult('9791234567896', CodeFormat.ean13).isbn, '9791234567896');
      // EAN-13 that is not a Bookland prefix.
      expect(const CodeResult('4006381333931', CodeFormat.ean13).isbn, isNull);
      // Right prefix, wrong symbology.
      expect(const CodeResult('9781234567897', CodeFormat.code128).isbn, isNull);
    });

    test('toString marks GS1 payloads', () {
      expect(const CodeResult('abc', CodeFormat.qrCode).toString(), 'qrCode: abc');
      expect(
        const CodeResult('0112345', CodeFormat.rss14, isGs1: true).toString(),
        'rss14·GS1: 0112345',
      );
    });

    test('defaults: no timestamp, not GS1, no points', () {
      const r = CodeResult('x', CodeFormat.qrCode);
      expect(r.timestamp, 0);
      expect(r.isGs1, isFalse);
      expect(r.windowPoints, isNull);
    });
  });

  group('RawDecode', () {
    test('carries the engine text, symbology and optional points', () {
      const d = RawDecode('hi', CodeFormat.code39, isGs1: true, points: [1, 2, 3, 4]);
      expect(d.text, 'hi');
      expect(d.format, CodeFormat.code39);
      expect(d.isGs1, isTrue);
      expect(d.points, [1, 2, 3, 4]);
      const plain = RawDecode('hi', CodeFormat.code39);
      expect(plain.isGs1, isFalse);
      expect(plain.points, isNull);
    });
  });

  test('ScanMode has exactly the continuous and one-shot delivery modes', () {
    expect(ScanMode.values, [ScanMode.continuous, ScanMode.oneShot]);
  });
}
