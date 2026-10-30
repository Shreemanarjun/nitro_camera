import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nitro_camera/native.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../logic/back_camera.dart';
import '../logic/bench_stats.dart';
import '../logic/image_bench.dart';

const _liveWindow = Duration(seconds: 6); // LIVE_MS_PER_ENGINE in the RN bench

typedef LiveReadout = ({double ms, double fps, double hitRatio, String? text});

/// The decode benchmark, mirroring react-native-nitro-zxing's BenchmarkScreen
/// so the numbers are like-for-like: a 6 s live-camera window (per-frame
/// engine time + whether it decoded), then the same bundled QR PNG ×30, with
/// identical statistics and a `[bench-json] {...}` log line. Full-frame
/// scanning; QR-only by default, ALL matches the RN app's `all-formats`.
class DecodeBenchController {
  final device = signal<CameraDeviceInfo?>(null);
  final status = signal('Starting…');
  final camera = signal<CameraController?>(null);
  final kind = signal(CodeScanKind.qr);

  /// Published every 500 ms — a per-frame write would rebuild at camera rate.
  final readout = signal<LiveReadout>((
    ms: 0.0,
    fps: 0.0,
    hitRatio: 0.0,
    text: null,
  ));
  final running = signal(false);
  final phase = signal('');
  final results = signal<List<BenchResult>>(const []);

  CodeScanner? _scanner;
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _ticker;
  double _lastMs = 0;
  int _framesInWindow = 0, _hitsInWindow = 0;
  String? _lastText;
  Collector? _live; // non-null while the live window is collecting
  bool _disposed = false;

  Future<void> init() async {
    final (cam, reason) = await acquireBackCamera();
    if (_disposed) return;
    if (cam == null) {
      status.value = reason;
      return;
    }
    NitroCamera.instance.setKeepScreenOn(1);
    device.value = cam;
  }

  Future<void> onCamera(CameraController c) async {
    camera.value = c;
    c.setPixelFormat(PixelFormat.yuv420); // the decoder reads the luma plane
    c.enableFrameProcessing();
    await _startScanner(kind.value);
  }

  void selectKind(CodeScanKind k) {
    if (running.value) return;
    kind.value = k;
    unawaited(_startScanner(k));
  }

  Future<void> run() async {
    final c = camera.value;
    if (running.value || c == null) return;
    batch(() {
      running.value = true;
      results.value = const [];
      phase.value = 'Live camera — ${_liveWindow.inSeconds}s';
    });
    try {
      final live = Collector();
      _live = live;
      await Future<void>.delayed(_liveWindow);
      _live = null;
      results.value = [
        ...results.value,
        live.result(
          'Live camera',
          '${c.width}x${c.height} YUV frames · ${_liveWindow.inSeconds}s',
        ),
      ];

      phase.value = 'Bundled image';
      final image = await runImageBench(kind.value);
      results.value = [...results.value, image];
      debugPrint('[bench-json] ${jsonEncode(results.value)}');
    } catch (e) {
      results.value = [...results.value, BenchResult.error(e)];
    } finally {
      _live = null;
      batch(() {
        running.value = false;
        phase.value = '';
      });
    }
  }

  Future<void> stopScanner() async {
    _ticker?.cancel();
    _ticker = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _scanner?.dispose();
    _scanner = null;
  }

  void dispose() {
    _disposed = true;
    unawaited(stopScanner());
    NitroCamera.instance.setKeepScreenOn(0);
  }

  Future<void> _startScanner(CodeScanKind k) async {
    await stopScanner();
    final scanner = CodeScanner(
      kind: k,
      windowFraction: 1.0,
    ); // full frame, like the RN app
    await scanner.start(NitroCamera.instance.frameStream);
    if (_disposed) {
      await scanner.dispose();
      return;
    }
    _scanner = scanner;
    _subs
      ..add(scanner.stats.listen(_onStats))
      ..add(scanner.detections.listen(_onDetection));
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void _onStats(FrameProcessStats s) {
    final ms = s.elapsedMicros / 1000;
    _framesInWindow++;
    _lastMs = ms;
    _live?.scan(ms);
  }

  void _onDetection(CodeResult r) {
    _hitsInWindow++;
    _lastText = '${r.format.name}: ${r.text}';
    _live?.hit(r.text);
  }

  void _tick() {
    readout.value = (
      ms: _lastMs,
      fps: _framesInWindow * 2.0,
      hitRatio: _framesInWindow == 0 ? 0.0 : _hitsInWindow / _framesInWindow,
      text: _lastText,
    );
    _framesInWindow = 0;
    _hitsInWindow = 0;
  }
}
