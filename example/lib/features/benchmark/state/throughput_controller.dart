import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nitro_camera/native.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../logic/back_camera.dart';
import '../logic/bench_stats.dart';
import '../logic/qr_server_client.dart';

enum ThroughputState {
  idle,
  preparing,
  running,
  completed,
  stopped,
  failed;

  bool get active => this == preparing || this == running;
}

/// The 1000-QR throughput run — the Flutter counterpart of
/// react-native-nitro-zxing PR #4 (and NativePHP PR #3) against the same
/// qr-server ([QrServerClient]). Same conventions: a fresh HTTP client per
/// run, untimed reset + warm-up request, camera mounted only for the run, the
/// first accepted scan is count 1 at t = 0, completion is timestamped at
/// accepted scan 1000 on a monotonic clock (999 timed intervals), duplicates
/// of the last submitted value are skipped, reports go through one serial
/// worker with no retry, and a transport error fails the run. Camera target
/// 640×480 @ 60 fps YUV like PR #4's Android profile — the negotiated values
/// are shown, because targets aren't guarantees.
/// Not mirrored: cancellation on backgrounding/navigation (just use Stop).
class ThroughputController {
  static const target = 1000;
  // Reached over USB: `adb reverse tcp:3000 tcp:3000` on the host running
  // qr-server. Use the host's LAN origin instead when the phone shares its Wi-Fi.
  static const defaultServer = 'http://127.0.0.1:3000';

  final device = signal<CameraDeviceInfo?>(
    null,
  ); // non-null only while a run has the camera mounted
  final state = signal(ThroughputState.idle);
  final count = signal(0);
  final elapsedMs = signal(0); // frozen when the run ends
  final error = signal<String?>(null);
  final config = signal('');
  final fps = signal(0.0);

  CodeScanner? _scanner;
  final _subs = <StreamSubscription<Object?>>[];
  QrServerClient? _client;
  Future<void> _reports = Future<void>.value(); // serial report worker
  Timer? _fpsTicker;
  final _clock = Stopwatch(); // monotonic; started by the first accepted scan
  String? _lastSubmitted;
  int _framesInWindow = 0;
  // Where the per-QR time goes (accepted scans only): HTTP round trip, time a
  // detection waited behind the previous report, frames the decoder saw.
  // Plain fields: only read once the run has ended.
  final _rttMs = <double>[];
  final _queueMs = <double>[];
  int _frames = 0;

  void init() => NitroCamera.instance.setKeepScreenOn(1);

  String get diagnostics {
    final rtt = Stats.of(_rttMs), queue = Stats.of(_queueMs);
    return 'http rtt median ${rtt.medianMs.toStringAsFixed(1)} · p95 ${rtt.p95Ms.toStringAsFixed(1)} ms · '
        'queue median ${queue.medianMs.toStringAsFixed(1)} · p95 ${queue.p95Ms.toStringAsFixed(1)} ms · '
        '$_frames frames analyzed';
  }

  Future<void> start(String origin) async {
    if (state.value.active) return;
    batch(() {
      state.value = ThroughputState.preparing;
      count.value = 0;
      elapsedMs.value = 0;
      error.value = null;
      config.value = '';
    });
    _lastSubmitted = null;
    _clock.reset();
    _rttMs.clear();
    _queueMs.clear();
    _frames = 0;
    final client = QrServerClient(Uri.parse(origin.trim()));
    _client = client;
    try {
      if (!await client.reset()) throw StateError('Server reset failed');
      await client.status();
      final (cam, reason) = await acquireBackCamera();
      if (cam == null) throw StateError(reason);
      if (state.value != ThroughputState.preparing) return; // stopped meanwhile
      batch(() {
        state.value = ThroughputState.running;
        device.value = cam; // mounts the CameraView → onCamera
      });
      _fpsTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        fps.value = _framesInWindow * 2.0;
        _framesInWindow = 0;
      });
    } catch (e) {
      if (state.value != ThroughputState.preparing) return;
      error.value = '$e';
      _finish(ThroughputState.failed);
    }
  }

  Future<void> onCamera(CameraController c) async {
    c.setPixelFormat(PixelFormat.yuv420);
    c.enableFrameProcessing();
    // Native read-back of the live session — resolvedConfig is null here
    // because CameraView was given a size, not a CameraDeviceFormat.
    final s = c.getSessionState();
    config.value =
        'Requested 640×480 @ 60 fps YUV; got ${s.width}×${s.height} @ ${s.fps} fps, ${s.pixelFormat.name}';
    await stopScanner();
    final scanner = CodeScanner(kind: CodeScanKind.qr, windowFraction: 1.0);
    await scanner.start(NitroCamera.instance.frameStream);
    if (state.value != ThroughputState.running) {
      await scanner.dispose();
      return;
    }
    _scanner = scanner;
    _subs
      ..add(
        scanner.stats.listen((_) {
          _framesInWindow++;
          _frames++;
        }),
      )
      ..add(
        scanner.detections.listen((r) => _submit(r.text)),
      ); // every raw hit, no confirmer
  }

  void stop() {
    if (!state.value.active) return;
    elapsedMs.value = _clock.elapsedMilliseconds;
    _clock.stop();
    _finish(ThroughputState.stopped);
  }

  Future<void> stopScanner() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _scanner?.dispose();
    _scanner = null;
  }

  void dispose() {
    stop();
    NitroCamera.instance.setKeepScreenOn(0);
  }

  void _submit(String value) {
    if (state.value != ThroughputState.running || value == _lastSubmitted) {
      return;
    }
    _lastSubmitted = value;
    final client = _client;
    if (client == null) return;
    final sw = Stopwatch()..start();
    _reports = _reports.then((_) async {
      if (state.value != ThroughputState.running) return;
      try {
        final queued = sw.elapsedMicroseconds / 1000;
        sw.reset();
        final ok = await client.scan(value);
        final rtt = sw.elapsedMicroseconds / 1000;
        if (!ok || state.value != ThroughputState.running) return;
        if (!_clock.isRunning) _clock.start(); // count 1 at t = 0
        batch(() {
          count.value++;
          elapsedMs.value = _clock.elapsedMilliseconds;
        });
        _rttMs.add(rtt);
        _queueMs.add(queued);
        if (count.value == target) {
          _clock.stop();
          debugPrint(
            '[throughput-json] ${jsonEncode({'engine': 'nitro_camera-zxing', 'target': target, 'elapsedMs': elapsedMs.value, 'intervals': target - 1, 'config': config.value, 'framesAnalyzed': _frames, 'httpRttMs': Stats.of(_rttMs).toJson(), 'queueDelayMs': Stats.of(_queueMs).toJson()})}',
          );
          _finish(ThroughputState.completed);
        }
      } catch (e) {
        if (state.value != ThroughputState.running) return;
        batch(() {
          elapsedMs.value = _clock.elapsedMilliseconds;
          error.value = '$e';
        });
        _finish(ThroughputState.failed);
      }
    });
  }

  /// Ends the run: freezes state, drops the HTTP client, unmounts the camera.
  void _finish(ThroughputState end) {
    _client?.close();
    _client = null;
    _fpsTicker?.cancel();
    _fpsTicker = null;
    unawaited(stopScanner());
    batch(() {
      state.value = end;
      device.value = null;
    });
  }
}
