import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/native.dart' show CameraConfig, FlashModeNativeExt, AutoFocusModeNativeExt, VideoStabilizationModeNativeExt;
import 'package:nitro_camera/nitro_camera.dart';

/// Gap-closing tests for the declarative configuration layer: the FFI
/// projection, every `diff()` field mapping, and each constraint's penalty.

CameraDeviceFormat _fmt({
  int videoWidth = 1920,
  int videoHeight = 1080,
  int photoWidth = 4032,
  int photoHeight = 3024,
  double minFps = 1,
  double maxFps = 60,
  bool videoHdr = false,
  bool photoHdr = false,
  AutoFocusSystem af = AutoFocusSystem.none,
  List<VideoStabilizationMode> stabilization = const [VideoStabilizationMode.off],
}) => CameraDeviceFormat(
  photoWidth: photoWidth,
  photoHeight: photoHeight,
  videoWidth: videoWidth,
  videoHeight: videoHeight,
  minFps: minFps,
  maxFps: maxFps,
  supportsVideoHdr: videoHdr,
  supportsPhotoHdr: photoHdr,
  autoFocusSystem: af,
  videoStabilizationModes: stabilization,
);

CameraDeviceInfo _device(List<CameraDeviceFormat> formats) => CameraDeviceInfo(
  id: 'dev',
  name: 'Dev',
  position: CameraPosition.back,
  lensType: CameraLensType.wideAngle,
  sensorOrientation: 90,
  minZoom: 1,
  maxZoom: 8,
  neutralZoom: 1,
  hasFlash: true,
  hasTorch: true,
  maxPhotoWidth: 4032,
  maxPhotoHeight: 3024,
  formats: formats,
);

/// The names of the fields a diff flagged — makes "only X changed" assertions
/// exact instead of a pile of individual `isFalse`s.
Set<String> _changed(CameraConfigurationDiff d) => {
  if (d.device) 'device',
  if (d.isActive) 'isActive',
  if (d.zoom) 'zoom',
  if (d.exposure) 'exposure',
  if (d.flash) 'flash',
  if (d.torch) 'torch',
  if (d.whiteBalance) 'whiteBalance',
  if (d.videoHdr) 'videoHdr',
  if (d.autoFocus) 'autoFocus',
  if (d.frameProcessing) 'frameProcessing',
  if (d.pixelFormat) 'pixelFormat',
  if (d.samplingRate) 'samplingRate',
  if (d.filter) 'filter',
};

void main() {
  group('CameraConfiguration.toNativeConfig', () {
    test('projects the live fields onto the FFI struct', () {
      final cfg = const CameraConfiguration().copyWith(
        zoom: 2.5,
        exposure: -1.5,
        flash: FlashMode.on,
        torch: true,
        whiteBalanceKelvin: 5600,
        videoHdr: true,
        lowLightBoost: true,
        autoFocus: AutoFocusMode.off,
        videoStabilization: VideoStabilizationMode.cinematic,
        isActive: true,
        enableFrameProcessing: true,
        pixelFormat: PixelFormat.yuv420,
        samplingRate: 3,
      );

      final native = cfg.toNativeConfig();
      expect(native, isA<CameraConfig>());
      expect(native.zoom, 2.5);
      expect(native.exposure, -1.5);
      expect(native.flash, FlashMode.on.nativeValue);
      expect(native.torch, 1);
      expect(native.torchLevel, 1.0);
      expect(native.whiteBalanceKelvin, 5600);
      expect(native.videoHdr, 1);
      expect(native.lowLightBoost, 1);
      expect(native.autoFocus, AutoFocusMode.off.nativeValue);
      expect(native.videoStabilization, VideoStabilizationMode.cinematic.nativeValue);
      expect(native.active, 1);
      expect(native.enableFrameProcessing, 1);
      expect(native.pixelFormat, PixelFormat.yuv420.nativeValue);
      expect(native.samplingRate, 3);
    });

    test('booleans project to 0 and the torch level follows the torch flag', () {
      final native = const CameraConfiguration(isActive: false).toNativeConfig();
      expect(native.torch, 0);
      expect(native.torchLevel, 0.0);
      expect(native.videoHdr, 0);
      expect(native.lowLightBoost, 0);
      expect(native.active, 0);
      expect(native.enableFrameProcessing, 0);
    });
  });

  group('CameraConfiguration.diff', () {
    const base = CameraConfiguration();

    test('a null previous means everything changed and a reopen is required', () {
      final d = base.diff(null);
      expect(d.requiresReopen, isTrue);
      expect(d.isEmpty, isFalse);
      expect(_changed(d), hasLength(13));
    });

    test('an identical previous is empty and needs no reopen', () {
      final d = base.diff(const CameraConfiguration());
      expect(d.isEmpty, isTrue);
      expect(d.requiresReopen, isFalse);
      expect(_changed(d), isEmpty);
    });

    test('deviceId / fps / audio / format each force a reopen', () {
      expect(_changed(base.copyWith(deviceId: 'other').diff(base)), {'device'});
      expect(_changed(base.copyWith(fps: 60).diff(base)), {'device'});
      expect(_changed(base.copyWith(enableAudio: true).diff(base)), {'device'});
      expect(_changed(base.copyWith(format: _fmt()).diff(base)), {'device'});
      expect(base.copyWith(fps: 60).diff(base).requiresReopen, isTrue);
    });

    test('two formats with the same resolution/fps key are NOT a reopen', () {
      final a = base.copyWith(format: _fmt());
      // Same width/height/maxFps/photo size, different ISO + HDR support.
      final b = base.copyWith(format: _fmt(videoHdr: true));
      expect(_changed(b.diff(a)), isEmpty);
      // ...but a different video resolution is.
      final c = base.copyWith(format: _fmt(videoWidth: 1280, videoHeight: 720));
      expect(_changed(c.diff(a)), {'device'});
    });

    test('every live-only field maps to exactly its own flag', () {
      final cases = <String, CameraConfiguration>{
        'isActive': base.copyWith(isActive: false),
        'zoom': base.copyWith(zoom: 2),
        'exposure': base.copyWith(exposure: 1),
        'flash': base.copyWith(flash: FlashMode.on),
        'torch': base.copyWith(torch: true),
        'whiteBalance': base.copyWith(whiteBalanceKelvin: 5000),
        'autoFocus': base.copyWith(autoFocus: AutoFocusMode.off),
        'frameProcessing': base.copyWith(enableFrameProcessing: true),
        'pixelFormat': base.copyWith(pixelFormat: PixelFormat.yuv420),
        'samplingRate': base.copyWith(samplingRate: 2),
        'filter': base.copyWith(filterShader: 'void main(){}'),
      };
      cases.forEach((field, next) {
        final d = next.diff(base);
        expect(_changed(d), {field}, reason: 'only $field should be flagged');
        expect(d.requiresReopen, isFalse, reason: '$field is a live update');
        expect(d.isEmpty, isFalse);
      });
    });

    test('videoHdr, lowLightBoost and stabilization share the videoHdr flag', () {
      for (final next in [
        base.copyWith(videoHdr: true),
        base.copyWith(lowLightBoost: true),
        base.copyWith(videoStabilization: VideoStabilizationMode.standard),
      ]) {
        expect(_changed(next.diff(base)), {'videoHdr'});
      }
    });

    test('several simultaneous changes are all reported', () {
      final next = base.copyWith(deviceId: 'x', zoom: 3, torch: true, samplingRate: 4);
      expect(_changed(next.diff(base)), {'device', 'zoom', 'torch', 'samplingRate'});
      expect(next.diff(base).requiresReopen, isTrue);
    });

    test('toString lists the changed fields in declaration order', () {
      expect(
        base.copyWith(zoom: 2, torch: true).diff(base).toString(),
        'CameraConfigurationDiff(zoom, torch)',
      );
      expect(base.diff(base).toString(), 'CameraConfigurationDiff()');
      expect(
        base.diff(null).toString(),
        'CameraConfigurationDiff(device, isActive, zoom, exposure, flash, torch, '
        'whiteBalance, videoHdr, autoFocus, frameProcessing, pixelFormat, '
        'samplingRate, filter)',
      );
    });
  });

  group('CameraConfiguration equality', () {
    test('copyWith with no arguments is equal and hash-equal', () {
      const a = CameraConfiguration(deviceId: 'd', zoom: 2, filterShader: 'x');
      final b = a.copyWith();
      expect(b, a);
      expect(b.hashCode, a.hashCode);
    });

    test('formats compare by their resolution key, not identity', () {
      final a = const CameraConfiguration().copyWith(format: _fmt());
      final b = const CameraConfiguration().copyWith(format: _fmt(videoHdr: true));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a different field breaks equality', () {
      const a = CameraConfiguration();
      expect(a == a.copyWith(zoom: 9), isFalse);
      expect(a == a.copyWith(filterShader: 'y'), isFalse);
      // ignore: unrelated_type_equality_checks
      expect(a == 'not a configuration', isFalse);
    });
  });

  group('FormatStats', () {
    test('an empty format list collapses every extent to zero', () {
      final s = FormatStats.from(const []);
      expect(s.minVideoArea, 0);
      expect(s.maxVideoArea, 0);
      expect(s.minPhotoArea, 0);
      expect(s.maxPhotoArea, 0);
    });

    test('tracks the min/max video and photo areas', () {
      final s = FormatStats.from([
        _fmt(videoWidth: 640, videoHeight: 480, photoWidth: 800, photoHeight: 600),
        _fmt(videoWidth: 1920, videoHeight: 1080, photoWidth: 4000, photoHeight: 3000),
      ]);
      expect(s.minVideoArea, 640 * 480);
      expect(s.maxVideoArea, 1920 * 1080);
      expect(s.minPhotoArea, 800 * 600);
      expect(s.maxPhotoArea, 4000 * 3000);
    });
  });

  group('constraint penalties', () {
    final stats = FormatStats.from([
      _fmt(videoWidth: 640, videoHeight: 480, photoWidth: 640, photoHeight: 480),
      _fmt(videoWidth: 1920, videoHeight: 1080, photoWidth: 4000, photoHeight: 3000),
    ]);

    test('FpsConstraint is free inside the range and grows outside it', () {
      final c = FpsConstraint(30);
      expect(c.fps, 30);
      expect(c.penalty(_fmt(minFps: 1, maxFps: 60), stats), 0);
      // Below the range: (24 - 30).abs() / 240.
      expect(FpsConstraint(24).penalty(_fmt(minFps: 30, maxFps: 60), stats), closeTo(6 / 240, 1e-9));
      // Above the range: (240 - 30) / 240.
      expect(FpsConstraint(240).penalty(_fmt(minFps: 1, maxFps: 30), stats), closeTo(210 / 240, 1e-9));
      // Clamped at 1.
      expect(FpsConstraint(1000).penalty(_fmt(minFps: 1, maxFps: 30), stats), 1.0);
    });

    test('TargetResolution factories build the matching subtype', () {
      expect(TargetResolution.max(), isA<MaxResolution>());
      expect(TargetResolution.min(), isA<MinResolution>());
      expect(TargetResolution.any(), isA<AnyResolution>());
      final closest = TargetResolution.closestTo(1280, 720) as ClosestResolution;
      expect(closest.width, 1280);
      expect(closest.height, 720);
    });

    test('AnyResolution never penalizes', () {
      final c = ResolutionConstraint(AnyResolution());
      expect(c.penalty(_fmt(videoWidth: 640, videoHeight: 480), stats), 0);
      expect(c.penalty(_fmt(videoWidth: 1920, videoHeight: 1080), stats), 0);
    });

    test('Max/MinResolution normalize against the field span', () {
      final maxC = ResolutionConstraint(MaxResolution());
      final minC = ResolutionConstraint(MinResolution());
      final small = _fmt(videoWidth: 640, videoHeight: 480);
      final large = _fmt(videoWidth: 1920, videoHeight: 1080);
      expect(maxC.penalty(large, stats), 0);
      expect(maxC.penalty(small, stats), 1);
      expect(minC.penalty(small, stats), 0);
      expect(minC.penalty(large, stats), 1);
    });

    test('Max/MinResolution are free when every format has the same area', () {
      final flat = FormatStats.from([_fmt(videoWidth: 100, videoHeight: 100, photoWidth: 100, photoHeight: 100)]);
      final f = _fmt(videoWidth: 100, videoHeight: 100, photoWidth: 100, photoHeight: 100);
      expect(ResolutionConstraint(MaxResolution()).penalty(f, flat), 0);
      expect(ResolutionConstraint(MinResolution()).penalty(f, flat), 0);
    });

    test('the photo stream scores the photo dimensions, not the video ones', () {
      final c = ResolutionConstraint(MaxResolution(), stream: StreamType.photo);
      expect(c.stream, StreamType.photo);
      // Big video, tiny photo -> maximal photo penalty.
      final f = _fmt(videoWidth: 1920, videoHeight: 1080, photoWidth: 640, photoHeight: 480);
      expect(c.penalty(f, stats), 1);
    });

    test('ClosestResolution: exact match is free, degenerate targets are free', () {
      final exact = ResolutionConstraint(ClosestResolution(1920, 1080));
      expect(exact.penalty(_fmt(videoWidth: 1920, videoHeight: 1080), stats), 0);
      expect(
        ResolutionConstraint(ClosestResolution(0, 0)).penalty(_fmt(), stats),
        0,
        reason: 'a zero target area cannot be scored',
      );
      expect(
        exact.penalty(_fmt(videoWidth: 0, videoHeight: 0), stats),
        0,
        reason: 'a zero candidate area cannot be scored',
      );
    });

    test('ClosestResolution penalizes aspect mismatch harder than pixel distance', () {
      final c = ResolutionConstraint(ClosestResolution(1920, 1080));
      final sameArAndSize = c.penalty(_fmt(videoWidth: 1280, videoHeight: 720), stats);
      // 4:3 with a similar pixel count -> aspect penalty dominates.
      final differentAr = c.penalty(_fmt(videoWidth: 1440, videoHeight: 1080), stats);
      expect(differentAr, greaterThan(sameArAndSize));
      for (final p in [sameArAndSize, differentAr]) {
        expect(p, inInclusiveRange(0.0, 1.0));
      }
    });

    test('VideoHdrConstraint only bites when HDR is requested', () {
      expect(VideoHdrConstraint(true).penalty(_fmt(videoHdr: false), stats), 1);
      expect(VideoHdrConstraint(true).penalty(_fmt(videoHdr: true), stats), 0);
      expect(VideoHdrConstraint(false).penalty(_fmt(videoHdr: false), stats), 0);
      expect(VideoHdrConstraint(true).enabled, isTrue);
    });

    test('PhotoHdrConstraint only bites when photo HDR is requested', () {
      expect(PhotoHdrConstraint(true).penalty(_fmt(photoHdr: false), stats), 1);
      expect(PhotoHdrConstraint(true).penalty(_fmt(photoHdr: true), stats), 0);
      expect(PhotoHdrConstraint(false).penalty(_fmt(photoHdr: false), stats), 0);
      expect(PhotoHdrConstraint(false).enabled, isFalse);
    });

    test('VideoStabilizationConstraint requires the exact mode', () {
      final c = VideoStabilizationConstraint(VideoStabilizationMode.cinematic);
      expect(c.mode, VideoStabilizationMode.cinematic);
      expect(c.penalty(_fmt(stabilization: const [VideoStabilizationMode.off]), stats), 1);
      expect(
        c.penalty(
          _fmt(stabilization: const [VideoStabilizationMode.off, VideoStabilizationMode.cinematic]),
          stats,
        ),
        0,
      );
    });

    test('AutoFocusConstraint requires the exact focus system', () {
      final c = AutoFocusConstraint(AutoFocusSystem.phaseDetection);
      expect(c.system, AutoFocusSystem.phaseDetection);
      expect(c.penalty(_fmt(af: AutoFocusSystem.phaseDetection), stats), 0);
      expect(c.penalty(_fmt(af: AutoFocusSystem.contrastDetection), stats), 1);
      expect(c.penalty(_fmt(af: AutoFocusSystem.none), stats), 1);
    });
  });

  group('FormatResolver', () {
    test('resolveConfig returns null when the device has no formats', () {
      expect(FormatResolver.resolveConfig(_device(const []), const []), isNull);
      expect(FormatResolver.resolve(_device(const []), const []), isNull);
      expect(_device(const []).bestFormat(), isNull);
    });

    test('resolveConfig defaults the fps to the format maximum', () {
      final device = _device([_fmt(minFps: 15, maxFps: 30, videoHdr: true)]);
      final cfg = FormatResolver.resolveConfig(device, const [], requestVideoHdr: true)!;
      expect(cfg.selectedFps, 30);
      expect(cfg.videoHdrEnabled, isTrue);
      expect(cfg.pixelFormat, PixelFormat.bgra);
      expect(cfg.videoWidth, 1920);
      expect(cfg.photoHeight, 3024);
    });

    test('resolveConfig cannot enable HDR the format does not support', () {
      final device = _device([_fmt(videoHdr: false)]);
      final cfg = FormatResolver.resolveConfig(device, const [], requestVideoHdr: true)!;
      expect(cfg.videoHdrEnabled, isFalse);
    });
  });
}
