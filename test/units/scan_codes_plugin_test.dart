import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// Rasterizes a QR into a luma plane, exactly as the frame pipeline delivers it.
FrameData _qrFrame(String text, {int side = 400}) {
  final matrix = QRCodeWriter().encode(text, BarcodeFormat.qrCode, side, side);
  final bytes = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      bytes[y * side + x] = matrix.get(x, y) ? 0 : 255;
    }
  }
  return FrameData(bytes: bytes, width: side, height: side, format: 0, bytesPerRow: side);
}

FrameData _noiseFrame({int side = 240}) {
  final bytes = Uint8List.fromList(
    List.generate(side * side, (i) => (i * 2654435761) % 251),
  );
  return FrameData(bytes: bytes, width: side, height: side, format: 0, bytesPerRow: side);
}

void main() {
  group('ScanCodesPlugin construction', () {
    test('resolves the kind named in the options', () {
      for (final kind in CodeScanKind.values) {
        expect(ScanCodesPlugin({'kind': kind.name}).kind, kind);
      }
    });

    test('defaults to CodeScanKind.all when no kind is given', () {
      expect(ScanCodesPlugin(const {}).kind, CodeScanKind.all);
      expect(ScanCodesPlugin(const {'other': 1}).kind, CodeScanKind.all);
    });

    test('falls back to CodeScanKind.all for an unknown or wrongly-typed kind', () {
      expect(ScanCodesPlugin(const {'kind': 'runes'}).kind, CodeScanKind.all);
      expect(ScanCodesPlugin(const {'kind': ''}).kind, CodeScanKind.all);
      expect(ScanCodesPlugin(const {'kind': 7}).kind, CodeScanKind.all);
      expect(ScanCodesPlugin(const {'kind': null}).kind, CodeScanKind.all);
    });

    test('is a FrameProcessorPlugin', () {
      expect(ScanCodesPlugin(const {}), isA<FrameProcessorPlugin>());
    });
  });

  group('ScanCodesPlugin.callback', () {
    test('returns the decoded payload as a plain map', () {
      final plugin = ScanCodesPlugin(const {'kind': 'qr'});

      final out = plugin.callback(_qrFrame('nitro://scan-codes'));

      expect(out, isA<Map<String, Object?>>());
      final map = out! as Map<String, Object?>;
      expect(map['text'], 'nitro://scan-codes');
      expect(map['format'], CodeFormat.qrCode.name);
      expect(map['isGs1'], isFalse);
      expect(map.keys, containsAll(<String>['text', 'format', 'isGs1', 'points']));
    });

    test('the payload is JSON-safe (isolate/plugin-channel friendly)', () {
      final map = ScanCodesPlugin(const {'kind': 'qr'}).callback(_qrFrame('json-safe'))! as Map<String, Object?>;

      expect(map['text'], isA<String>());
      expect(map['format'], isA<String>());
      expect(map['isGs1'], isA<bool>());
      final points = map['points'];
      expect(points == null || points is List<double>, isTrue, reason: 'points: $points');
    });

    test('returns null when there is nothing to decode', () {
      expect(ScanCodesPlugin(const {'kind': 'qr'}).callback(_noiseFrame()), isNull);
    });

    test('the configured kind gates what is decoded', () {
      final frame = _qrFrame('kind-routing');

      expect(ScanCodesPlugin(const {'kind': 'postal'}).callback(frame), isNull);
      expect(
        (ScanCodesPlugin(const {'kind': 'all'}).callback(frame)! as Map)['text'],
        'kind-routing',
      );
    });
  });

  group('registration', () {
    test('scanCodes is unavailable until the built-ins are registered', () {
      expect(FrameProcessorPlugins.isRegistered('scanCodes'), isFalse);
      expect(
        () => FrameProcessorPlugins.init('scanCodes'),
        throwsA(isA<ArgumentError>().having((e) => e.invalidValue, 'invalidValue', 'scanCodes')),
      );

      registerBuiltInFrameProcessorPlugins();

      expect(FrameProcessorPlugins.isRegistered('scanCodes'), isTrue);
      expect(FrameProcessorPlugins.registeredNames, contains('scanCodes'));
      expect(FrameProcessorPlugins.init('scanCodes').name, 'scanCodes');
    });

    test('registering twice is idempotent (hot-restart friendly)', () {
      registerBuiltInFrameProcessorPlugins();
      registerBuiltInFrameProcessorPlugins();

      expect(
        FrameProcessorPlugins.registeredNames.where((n) => n == 'scanCodes'),
        hasLength(1),
      );
    });

    test('the factory builds a plugin configured from its options', () {
      final plugin = createScanCodesPlugin(const {'kind': 'oneD'});

      expect(plugin, isA<ScanCodesPlugin>());
      expect((plugin as ScanCodesPlugin).kind, CodeScanKind.oneD);
    });

    test('an unrelated name still fails after registration', () {
      registerBuiltInFrameProcessorPlugins();

      expect(() => FrameProcessorPlugins.init('scanRunes'), throwsArgumentError);
    });
  });

  test('runs end-to-end through the plugin runner on a worker isolate', () async {
    registerBuiltInFrameProcessorPlugins();
    final runner = FrameProcessorPlugins.init('scanCodes', {'kind': 'qr'});
    await runner.start();

    final results = <Object?>[];
    final sub = runner.results.listen(results.add);

    runner.submit(_qrFrame('worker-isolate'));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(results, isNotEmpty);
    expect((results.first! as Map)['text'], 'worker-isolate');

    await sub.cancel();
    await runner.dispose();
  });
}
