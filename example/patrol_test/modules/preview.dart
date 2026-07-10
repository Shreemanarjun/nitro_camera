import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import '../support/frame_stats.dart';
import 'module.dart';

/// Production preview-quality module: sustained-FPS / no-stall stress tests
/// and image-level (pixel) validation of the preview, HDR and low-light boost.
final class Preview extends Module {
  Preview(super.$);

  CameraController get _ctrl => cameraStore.activeController.value!;

  /// Streams frames for [duration] and returns aggregate stats. Enables frame
  /// processing (drops it again after), with a short warm-up so first-frame
  /// pipeline setup doesn't skew the numbers.
  Future<FrameStreamReport> collectFor(
    Duration duration, {
    Duration warmup = const Duration(milliseconds: 600),
  }) async {
    final c = _ctrl;
    c.setFrameProcessing(enabled: true);
    await pumpFor(warmup);
    final collector = FrameStatsCollector();
    collector.attach(c.frameStream);
    await pumpFor(duration);
    final report = await collector.stop();
    c.setFrameProcessing(enabled: false);
    return report;
  }

  // ── Preview stability (no lag / no stall) ──────────────────────────────────

  /// Preview must sustain frames without stalling: a real FPS floor, no long
  /// inter-frame gap, and never a degenerate (black/blown) frame.
  Future<void> verifySustainedPreview() async {
    final r = await collectFor(const Duration(seconds: 4));
    // ignore: avoid_print
    print('sustained preview: $r');
    expect(r.frameCount, greaterThan(20),
        reason: 'too few frames in 4s — stream stalled ($r)');
    expect(r.fps, greaterThan(12),
        reason: 'preview FPS floor breached (lag): $r');
    expect(r.maxGapMs, lessThan(600),
        reason: 'preview stalled — ${r.maxGapMs}ms gap between frames ($r)');
    expect(r.allFramesValid, isTrue,
        reason: 'preview went black/blown at the pixel level ($r)');
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Hammer live config (zoom / exposure / HDR / low-light / stabilization /
  /// pixel-format) WHILE streaming — the preview must not lag, stall, black
  /// out, or error. This is the real-world "user drags the zoom slider and
  /// toggles settings" storm.
  Future<void> verifyConfigStormNoStall() async {
    final c = _ctrl;
    final device = c.device;
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 600));
    final collector = FrameStatsCollector();
    collector.attach(c.frameStream);

    const iterations = 20;
    for (var i = 0; i < iterations; i++) {
      final t = i / iterations;
      c.setZoom(device.minZoom + (device.maxZoom - device.minZoom) * t);
      c.setExposure((i % 3 - 1) * device.maxExposure / 2);
      c.setHdr(enabled: i % 2 == 0);
      c.setLowLightBoost(enabled: i % 3 == 0);
      c.setVideoStabilization(i % 2 == 0
          ? VideoStabilizationMode.standard
          : VideoStabilizationMode.off);
      await pumpFor(const Duration(milliseconds: 150));
    }

    final r = await collector.stop();
    c.setZoom(device.minZoom);
    c.setHdr(enabled: false);
    c.setLowLightBoost(enabled: false);
    c.setFrameProcessing(enabled: false);
    // ignore: avoid_print
    print('config storm: $r');

    expect(r.frameCount, greaterThan(10),
        reason: 'preview stalled during a config storm ($r)');
    expect(r.maxGapMs, lessThan(1500),
        reason: 'long preview stall during config storm — ${r.maxGapMs}ms ($r)');
    expect(r.allFramesValid, isTrue,
        reason: 'preview went black during config storm ($r)');
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull,
        reason: 'a config storm must not surface a native error');
  }

  /// Sweep zoom min→max→min in steps while streaming — frames must flow
  /// throughout (no stall on zoom changes, a common preview-freeze trigger).
  Future<void> verifyZoomSweepNoStall() async {
    final c = _ctrl;
    final device = c.device;
    if (device.maxZoom <= device.minZoom) {
      // Fixed-zoom lens — nothing to sweep.
      return;
    }
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 600));
    final collector = FrameStatsCollector();
    collector.attach(c.frameStream);

    const steps = 12;
    for (var i = 0; i <= steps; i++) {
      c.setZoom(device.minZoom +
          (device.maxZoom - device.minZoom) * (i / steps));
      await pumpFor(const Duration(milliseconds: 120));
    }
    for (var i = steps; i >= 0; i--) {
      c.setZoom(device.minZoom +
          (device.maxZoom - device.minZoom) * (i / steps));
      await pumpFor(const Duration(milliseconds: 120));
    }

    final r = await collector.stop();
    c.setZoom(device.minZoom);
    c.setFrameProcessing(enabled: false);
    // ignore: avoid_print
    print('zoom sweep: $r');
    expect(r.frameCount, greaterThan(15), reason: 'preview stalled during zoom sweep ($r)');
    expect(r.maxGapMs, lessThan(800), reason: 'zoom sweep stalled the preview ($r)');
    expect(r.allFramesValid, isTrue);
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Capture a burst of photos WHILE the preview streams — the preview must
  /// keep delivering frames across each capture (no freeze during capture)
  /// and every photo must return.
  Future<void> verifyCaptureBurstDuringStream() async {
    final c = _ctrl;
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 600));
    final collector = FrameStatsCollector();
    collector.attach(c.frameStream);

    for (var i = 0; i < 4; i++) {
      final p = await c.takePhoto();
      expect(File(p.path).existsSync(), isTrue, reason: 'burst photo #$i missing');
      File(p.path).deleteSync();
      await pumpFor(const Duration(milliseconds: 400));
    }

    final r = await collector.stop();
    c.setFrameProcessing(enabled: false);
    // ignore: avoid_print
    print('capture burst during stream: $r');
    expect(r.frameCount, greaterThan(10),
        reason: 'preview froze during capture burst ($r)');
    expect(r.allFramesValid, isTrue);
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Long continuous stream: the frame rate at the END of a ~13s stream must
  /// not have degraded vs the START (a leak, buffer starvation, or thermal
  /// throttle would show up here), and no stall or degenerate frame throughout.
  Future<void> verifyLongStreamStability() async {
    final c = _ctrl;
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 600));

    final early = FrameStatsCollector()..attach(c.frameStream);
    await pumpFor(const Duration(seconds: 4));
    final e = await early.stop();

    await pumpFor(const Duration(seconds: 5)); // keep streaming, uncollected

    final tail = FrameStatsCollector()..attach(c.frameStream);
    await pumpFor(const Duration(seconds: 4));
    final l = await tail.stop();

    c.setFrameProcessing(enabled: false);
    // ignore: avoid_print
    print('long stream: early=$e  late=$l');
    expect(e.allFramesValid && l.allFramesValid, isTrue,
        reason: 'degenerate frame during a long stream (early=$e late=$l)');
    expect(l.fps, greaterThan(e.fps * 0.7),
        reason: 'FPS degraded over time — leak/throttle? early=${e.fps} '
            'late=${l.fps}');
    expect(l.maxGapMs, lessThan(700),
        reason: 'preview stalled late in a long stream ($l)');
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Re-applying the SAME configuration must be a no-op — no session reopen
  /// (textureId unchanged) and no preview stall (vision-camera's
  /// diff-don't-recreate guard).
  Future<void> verifyNoOpReconfigureNoStall() async {
    final c = _ctrl;
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(milliseconds: 600));
    // Capture base AFTER enabling frame processing so it reflects the CURRENT
    // live state — configure(base) is then a genuine empty-diff no-op (a base
    // captured earlier would carry enableFrameProcessing:false and the apply
    // would actually turn frame delivery off).
    final base = c.configuration!;
    final tid = c.textureId;
    final col = FrameStatsCollector()..attach(c.frameStream);

    for (var i = 0; i < 5; i++) {
      await c.configure(base); // identical config
      await pumpFor(const Duration(milliseconds: 300));
    }

    final r = await col.stop();
    c.setFrameProcessing(enabled: false);
    // ignore: avoid_print
    print('no-op reconfigure: $r');
    expect(c.textureId, tid,
        reason: 'a no-op reconfigure reopened the session (tid changed)');
    expect(r.maxGapMs, lessThan(700),
        reason: 'a no-op reconfigure stalled the preview ($r)');
    expect(r.allFramesValid, isTrue);
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Frame-drop reasons stream is wired end-to-end (native emit → typed
  /// parse). Drops are load-dependent so the count may be zero, but ANY that
  /// fire must be a valid typed [FrameDropReason], and the session stays live.
  Future<void> verifyFrameDropReasonsWired() async {
    final c = _ctrl;
    final reasons = <FrameDropReason>[];
    final sub = c.frameDropReasons.listen(reasons.add);
    c.setSamplingRate(1);
    c.setFrameProcessing(enabled: true);
    await pumpFor(const Duration(seconds: 3));
    c.setFrameProcessing(enabled: false);
    await sub.cancel();
    // ignore: avoid_print
    print('frame-drop reasons observed: ${reasons.map((r) => r.name).toList()}');
    for (final r in reasons) {
      expect(FrameDropReason.values, contains(r));
    }
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
  }

  /// Thermal state via the CONTROLLER stream (controller.thermalStates), the
  /// app-facing API (thermal_state_test covers the raw event path). A reopen
  /// re-publishes the current state.
  Future<void> verifyThermalViaControllerStream() async {
    final states = <ThermalState>[];
    final sub = _ctrl.thermalStates.listen(states.add);
    final beforeTid = cameraStore.activeTextureId.value;
    cameraStore.setResolution(1280, 720);
    await pumpUntil(
      () =>
          cameraStore.activeTextureId.value != beforeTid && states.isNotEmpty,
      timeout: const Duration(seconds: 15),
      reason: 'controller.thermalStates published a state on reopen',
    );
    await sub.cancel();
    expect(ThermalState.values, contains(states.first));
    cameraStore.setResolution(1920, 1080);
    await pumpFor(const Duration(seconds: 1));
    expect(cameraStore.errorMessage.value, isNull);
  }

  // ── Image-level HDR / low-light validation ─────────────────────────────────

  /// Low-light boost, validated at the PIXEL level: enabling it must not
  /// darken the image (it brightens on dark scenes), the stream stays valid,
  /// and the session survives. Returns false when unsupported (caller skips).
  Future<bool> verifyLowLightBoostImage() async {
    final c = _ctrl;
    if (!c.device.supportsLowLightBoost) return false;

    c.setLowLightBoost(enabled: false);
    await pumpFor(const Duration(seconds: 1));
    final off = await collectFor(const Duration(seconds: 2));

    c.setLowLightBoost(enabled: true);
    await pumpFor(const Duration(milliseconds: 1500)); // let AE/gain settle
    final on = await collectFor(const Duration(seconds: 2));

    c.setLowLightBoost(enabled: false);
    // ignore: avoid_print
    print('low-light boost: off=$off  on=$on  '
        'deltaLuma=${(on.meanLuma - off.meanLuma).toStringAsFixed(1)}');

    expect(off.allFramesValid && on.allFramesValid, isTrue,
        reason: 'low-light boost produced degenerate frames (off=$off on=$on)');
    // Directional: boost brightens or is neutral — it must NOT darken the
    // scene (a small tolerance absorbs AE noise).
    expect(on.meanLuma, greaterThanOrEqualTo(off.meanLuma - 4.0),
        reason: 'low-light boost DARKENED the image (off=${off.meanLuma}, '
            'on=${on.meanLuma})');
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
    return true;
  }

  /// Video HDR, validated at the PIXEL level: when the active format supports
  /// it, HDR must actually engage (resolved read-back), the stream stays
  /// valid, and dynamic range must not collapse vs SDR. Returns a status:
  ///   'ok' | 'no-hdr-format' | 'not-active' (advertised but the active format
  ///   couldn't engage it — caller skips).
  Future<String> verifyHdrImage() async {
    final c = _ctrl;
    if (!c.device.formats.any((f) => f.supportsVideoHdr)) return 'no-hdr-format';

    final base = c.configuration;
    if (base == null) return 'no-hdr-format';

    // SDR baseline.
    await c.configure(base.copyWith(videoHdr: false));
    await pumpFor(const Duration(milliseconds: 800));
    final sdr = await collectFor(const Duration(seconds: 2));

    // Request HDR and read back whether it actually engaged.
    await c.configure(c.configuration!.copyWith(videoHdr: true));
    await pumpFor(const Duration(milliseconds: 800));
    final engaged = c.resolvedConfig?.videoHdrEnabled ?? false;
    if (!engaged) {
      await c.configure(c.configuration!.copyWith(videoHdr: false));
      return 'not-active';
    }
    final hdr = await collectFor(const Duration(seconds: 2));

    await c.configure(c.configuration!.copyWith(videoHdr: false));
    // ignore: avoid_print
    print('HDR: sdr=$sdr  hdr=$hdr  '
        'rangeDelta=${hdr.dynamicRange - sdr.dynamicRange}');

    expect(sdr.allFramesValid && hdr.allFramesValid, isTrue,
        reason: 'HDR produced degenerate frames (sdr=$sdr hdr=$hdr)');
    // HDR must not COLLAPSE tonal range vs SDR (it preserves/extends it). A
    // generous margin absorbs scene/AE variation between the two windows.
    expect(hdr.dynamicRange, greaterThanOrEqualTo(sdr.dynamicRange - 25),
        reason: 'HDR collapsed dynamic range vs SDR (sdr=${sdr.dynamicRange}, '
            'hdr=${hdr.dynamicRange})');
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.errorMessage.value, isNull);
    return 'ok';
  }
}
