import 'dart:isolate';

import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_zxing/nitro_zxing.dart';

import 'qr_server_client.dart';

// Worker-isolate side of the throughput run — the Flutter analogue of
// react-native-nitro-zxing PR #4's native reporter called from the frame
// worklet: decode AND report on the frame worker, so no hit, POST or reply
// ever waits behind the UI isolate. The UI only gets progress messages.
//
// These globals live in the CameraFrameProcessor's worker isolate (one run
// per worker): [throughputWorkerInit] sets them up, [throughputFrameHandler]
// runs per frame.

QrServerClient? _client;
SendPort? _toUi;
Future<void> _reports = Future<void>.value(); // serial report worker
String? _lastSubmitted;
final _clock = Stopwatch(); // started by the first accepted scan
var _count = 0;
var _target = 0;
var _cpp = false; // zxing-cpp (nitro_zxing) instead of the Dart scanner
final _rttMs = <double>[];
final _queueMs = <double>[];

/// Messages the worker sends to the UI isolate.
sealed class ThroughputEvent {}

/// An accepted scan: [count] so far at [elapsedMs] on the run clock.
class ThroughputAccepted extends ThroughputEvent {
  final int count, elapsedMs;
  ThroughputAccepted(this.count, this.elapsedMs);
}

/// The [_target]-th scan was accepted; per-QR HTTP round trips and report
/// queue delays for the log line.
class ThroughputDone extends ThroughputEvent {
  final int elapsedMs;
  final List<double> rttMs, queueMs;
  ThroughputDone(this.elapsedMs, this.rttMs, this.queueMs);
}

/// A transport error failed the run (no retry — see [QrServerClient]).
class ThroughputFailed extends ThroughputEvent {
  final String error;
  final int elapsedMs;
  ThroughputFailed(this.error, this.elapsedMs);
}

/// `workerInitArg` = (server origin, target, UI SendPort, use zxing-cpp).
void throughputWorkerInit(Object? arg) {
  final (origin, target, toUi, cpp) = arg as (String, int, SendPort, bool);
  _cpp = cpp;
  scannerWorkerInit(1.0); // full frame, like the RN app
  _client = QrServerClient(Uri.parse(origin));
  _target = target;
  _toUi = toUi;
}

/// Per-frame handler: decode, and report a new value straight from here.
// TEMP latency probe: native emit (wall-clock ms) → handler start, and decode.
final _lat = <int>[];
final _dec = <int>[];
final _probe = Stopwatch()..start();
// Frames handled per QR: from the frame after the previous new value to the
// first frame that decodes the next one (misses before a hit + 1).
var _sinceNew = 0;
final _perQr = <int, int>{};

bool throughputFrameHandler(FrameData f) {
  _lat.add(DateTime.now().millisecondsSinceEpoch - f.timestamp);
  final t0 = _probe.elapsedMicroseconds;
  final r = _cpp ? _decodeCpp(f) : scanFrameAdaptive(f, CodeScanKind.qr)?.text;
  _dec.add(_probe.elapsedMicroseconds - t0);
  _sinceNew++;
  if (r != null && r != _lastSubmitted && _count < _target) {
    _perQr[_sinceNew] = (_perQr[_sinceNew] ?? 0) + 1;
    _sinceNew = 0;
  }
  if (_count == _target - 1 && _perQr.isNotEmpty) {
    final h = (_perQr.entries.toList()..sort((a, b) => a.key - b.key));
    // ignore: avoid_print
    print('[probe] frames per QR: ${h.map((e) => '${e.key}:${e.value}').join(' ')}');
    _perQr.clear();
  }
  if (_lat.length == 600) {
    _lat.sort();
    _dec.sort();
    // ignore: avoid_print
    print('[probe] emit→handler ms p50=${_lat[300]} p90=${_lat[540]} max=${_lat.last} '
        'decode us p50=${_dec[300]} p90=${_dec[540]}');
    _lat.clear();
    _dec.clear();
  }
  if (r != null) _submit(r); // every raw hit, no confirmer
  return r != null;
}

/// The frame's luma plane through zxing-cpp; null on a miss.
String? _decodeCpp(FrameData f) {
  final r = NitroZxing.instance.decodeLuma(f.bytes, f.width, f.height, f.effectiveBytesPerRow, ZxingFormat.qrCode, true);
  return r.text.isEmpty ? null : r.text;
}

void _submit(String value) {
  final client = _client;
  if (client == null || value == _lastSubmitted || _count >= _target) return;
  _lastSubmitted = value;
  final sw = Stopwatch()..start();
  _reports = _reports.then((_) async {
    if (_client == null) return; // failed earlier
    try {
      final queued = sw.elapsedMicroseconds / 1000;
      sw.reset();
      final ok = await client.scan(value);
      final rtt = sw.elapsedMicroseconds / 1000;
      if (!ok || _count >= _target) return;
      if (!_clock.isRunning) _clock.start(); // count 1 at t = 0
      _count++;
      _rttMs.add(rtt);
      _queueMs.add(queued);
      if (_count == _target) {
        _clock.stop();
        _toUi?.send(
          ThroughputDone(_clock.elapsedMilliseconds, _rttMs, _queueMs),
        );
      } else {
        _toUi?.send(ThroughputAccepted(_count, _clock.elapsedMilliseconds));
      }
    } catch (e) {
      _client = null;
      _toUi?.send(ThroughputFailed('$e', _clock.elapsedMilliseconds));
    }
  });
}
