import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

CameraDeviceFormat fmt({int w = 1920, int h = 1080, double maxFps = 30}) =>
    CameraDeviceFormat(
      photoWidth: w,
      photoHeight: h,
      videoWidth: w,
      videoHeight: h,
      minFps: 30,
      maxFps: maxFps,
    );

void main() {
  group('CameraConfiguration.copyWith', () {
    test('changes one field and preserves the rest', () {
      const base = CameraConfiguration(deviceId: 'a', fps: 30, zoom: 1.0);
      final next = base.copyWith(zoom: 2.0);
      expect(next.zoom, 2.0);
      expect(next.deviceId, 'a');
      expect(next.fps, 30);
      expect(base.zoom, 1.0, reason: 'original is immutable');
    });
  });

  group('CameraConfiguration.diff', () {
    const base = CameraConfiguration(deviceId: 'a', fps: 30);

    test('no change -> empty diff', () {
      final d = base.diff(base);
      expect(d.isEmpty, isTrue);
      expect(d.requiresReopen, isFalse);
    });

    test('zoom change is a cheap live update (no reopen)', () {
      final d = base.copyWith(zoom: 3.0).diff(base);
      expect(d.zoom, isTrue);
      expect(d.requiresReopen, isFalse);
      expect(d.isEmpty, isFalse);
    });

    test('device change requires reopen', () {
      final d = base.copyWith(deviceId: 'b').diff(base);
      expect(d.device, isTrue);
      expect(d.requiresReopen, isTrue);
    });

    test('fps change requires reopen', () {
      expect(base.copyWith(fps: 60).diff(base).requiresReopen, isTrue);
    });

    test('audio change requires reopen', () {
      expect(base.copyWith(enableAudio: true).diff(base).requiresReopen, isTrue);
    });

    test('format resolution change requires reopen', () {
      final a = base.copyWith(format: fmt(w: 1920, h: 1080));
      final b = a.copyWith(format: fmt(w: 1280, h: 720));
      expect(b.diff(a).requiresReopen, isTrue);
    });

    test('multiple live changes are all reported, none reopen', () {
      final d = base
          .copyWith(torch: true, flash: FlashMode.on, samplingRate: 2)
          .diff(base);
      expect(d.torch, isTrue);
      expect(d.flash, isTrue);
      expect(d.samplingRate, isTrue);
      expect(d.requiresReopen, isFalse);
    });

    test('diff against null treats everything as changed', () {
      final d = base.diff(null);
      expect(d.isEmpty, isFalse);
      expect(d.requiresReopen, isTrue);
    });
  });

  group('CameraConfiguration equality', () {
    test('equal configs compare equal and share a hashCode', () {
      const a = CameraConfiguration(deviceId: 'x', fps: 30, zoom: 1.5);
      const b = CameraConfiguration(deviceId: 'x', fps: 30, zoom: 1.5);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different configs are not equal', () {
      const a = CameraConfiguration(deviceId: 'x');
      const b = CameraConfiguration(deviceId: 'y');
      expect(a, isNot(equals(b)));
    });
  });
}
