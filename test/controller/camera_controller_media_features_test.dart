import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';
import 'controller_fixtures.dart';

/// Overlay drawing, camera extensions and the GPU resizer: what reaches
/// native and the typed errors.
void main() {
  late FakeNitroCamera fake;
  late CameraController c;

  setUp(() async {
    fake = FakeNitroCamera();
    c = CameraController(device: testDevice(), native: fake);
    await c.initialize();
    fake.clear();
  });

  tearDown(() async {
    await c.dispose();
    await fake.close();
  });

  group('setOverlay', () {
    test('sends the encoded overlay; null clears', () {
      final o = CameraOverlay()..rect(const Rect.fromLTWH(0, 0, 1, 1), color: const Color(0xFFFFFFFF));
      c.setOverlay(o);
      expect(fake.argsOf('updateOverlay')![1], o.encode());
      c.setOverlay(null);
      expect(fake.argsOf('updateOverlay')![1], CameraOverlay().encode());
    });
  });

  group('setExtension', () {
    test('passes the extension name; null turns it off', () async {
      await c.setExtension(CameraExtension.night);
      expect(fake.argsOf('setCameraExtension'), [7, 'night']);
      await c.setExtension(null);
      expect(fake.argsOf('setCameraExtension'), [7, '']);
    });

    test('maps EXTENSION_UNSUPPORTED and SESSION_BUSY', () async {
      fake.failWith('setCameraExtension', Exception('EXTENSION_UNSUPPORTED: no night here'));
      await expectLater(
        c.setExtension(CameraExtension.night),
        throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'device/extension-unsupported')),
      );
      fake.failWith('setCameraExtension', Exception('SESSION_BUSY: recording'));
      await expectLater(
        c.setExtension(CameraExtension.hdr),
        throwsA(isA<SessionException>().having((e) => e.code, 'code', 'session/busy')),
      );
    });
  });

  group('multi-cam', () {
    test('setMultiCamEnabled reaches native', () {
      CameraController.setMultiCamEnabled(true, native: fake);
      expect(fake.argsOf('setMultiCamEnabled'), [1]);
      CameraController.setMultiCamEnabled(false, native: fake);
      expect(fake.argsOf('setMultiCamEnabled'), [0]);
    });
  });

  group('GPU resizer', () {
    ResizedFrame tensor(int textureId) => ResizedFrame(
      data: Float32List.fromList([0.5, 0.25, 1]).buffer.asUint8List(),
      size: 12,
      width: 1,
      height: 1,
      channels: 3,
      dataType: 1,
      timestamp: 1,
      textureId: textureId,
    );

    test('options reach native; stopResizer disables', () async {
      await c.setResizer(const ResizerOptions(width: 192, height: 192, dataType: 1, channelOrder: 1, scaleMode: 1));
      final o = fake.argsOf('setResizer')![1] as ResizerOptions;
      expect((o.enabled, o.width, o.height, o.channels, o.dataType, o.channelOrder, o.scaleMode), (1, 192, 192, 3, 1, 1, 1));
      await c.stopResizer();
      expect((fake.argsOf('setResizer')![1] as ResizerOptions).enabled, 0);
    });

    test('rejects a bad size or channel count before reaching native', () async {
      await expectLater(c.setResizer(const ResizerOptions(width: 0)), throwsArgumentError);
      await expectLater(c.setResizer(const ResizerOptions(channels: 2)), throwsArgumentError);
      expect(fake.called('setResizer'), isFalse);
    });

    test('resizedFrames carries only this session\'s tensors, typed', () async {
      final seen = <List<double>>[];
      final sub = c.resizedFrames.listen((t) => seen.add(t.float32.toList()));
      fake.emitResized(tensor(99));
      fake.emitResized(tensor(7));
      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        [0.5, 0.25, 1.0],
      ]);
      await sub.cancel();
    });
  });
}
