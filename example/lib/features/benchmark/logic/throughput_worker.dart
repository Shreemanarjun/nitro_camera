import 'dart:ffi';
import 'dart:isolate';

import 'package:nitro/nitro.dart' show NitroBuffer;
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
bool throughputFrameHandler(FrameData f) {
  final start = _bootUs();
  final r = _cpp ? _decodeCpp(f) : scanFrameAdaptive(f, CodeScanKind.qr)?.text;
  final end = _bootUs();
  _probeFrame(f.timestamp ~/ 1000, start, end);
  if (r != null) _submit(r, f.timestamp ~/ 1000, start, end); // every raw hit, no confirmer
  return r != null;
}

// TEMP stage probe (same rows as the RN app's QrProbe): every time is CLOCK_BOOTTIME
// µs, the clock of the sensor timestamp nitro_camera temporarily puts in
// CameraFrame.timestamp (ns).
final _bootClock = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Pointer<Int64>), int Function(int, Pointer<Int64>)>('clock_gettime');
// Keep the buffer itself: holding only its pointer lets the GC finalizer free it.
final _timespecBuf = NitroBuffer(16);
int _bootUs() {
  final ts = _timespecBuf.pointer.cast<Int64>();
  _bootClock(7 /* CLOCK_BOOTTIME */, ts);
  return ts[0] * 1000000 + ts[1] ~/ 1000;
}

final _deliveryUs = <int>[], _decodeUs = <int>[];
var _framesSinceHit = 0;
final _rows = <String>[];

void _probeFrame(int capUs, int startUs, int endUs) {
  _deliveryUs.add(startUs - capUs);
  _decodeUs.add(endUs - startUs);
  _framesSinceHit++;
}

int _pct(List<int> v, double p) => (v.toList()..sort())[((v.length - 1) * p).round()];

void _dumpProbe() {
  // ignore: avoid_print
  print('[qrframes] n=${_deliveryUs.length} delivery p50=${_pct(_deliveryUs, .5)} p90=${_pct(_deliveryUs, .9)} '
      'decode p50=${_pct(_decodeUs, .5)} p90=${_pct(_decodeUs, .9)}');
  for (var i = 0; i < _rows.length; i += 12) {
    // ignore: avoid_print
    print('[qrrows] ${_rows.skip(i).take(12).join(';')}');
  }
}

/// The frame's luma plane through zxing-cpp; null on a miss.
String? _decodeCpp(FrameData f) {
  final r = NitroZxing.instance.decodeLuma(f.bytes, f.width, f.height, f.effectiveBytesPerRow, ZxingFormat.qrCode, true);
  return r.text.isEmpty ? null : r.text;
}

void _submit(String value, int capUs, int startUs, int decodedUs) {
  final client = _client;
  if (client == null || value == _lastSubmitted || _count >= _target) return;
  _lastSubmitted = value;
  final frames = _framesSinceHit;
  _framesSinceHit = 0;
  final sw = Stopwatch()..start();
  _reports = _reports.then((_) async {
    if (_client == null) return; // failed earlier
    try {
      final queued = sw.elapsedMicroseconds / 1000;
      sw.reset();
      final post0 = _bootUs();
      final ok = await client.scan(value);
      final post1 = _bootUs();
      final rtt = sw.elapsedMicroseconds / 1000;
      if (!ok || _count >= _target) return;
      if (!_clock.isRunning) _clock.start(); // count 1 at t = 0
      _count++;
      _rows.add('$capUs,$startUs,$decodedUs,$post0,$post1,$frames');
      _rttMs.add(rtt);
      _queueMs.add(queued);
      if (_count == _target) {
        _clock.stop();
        _dumpProbe();
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
