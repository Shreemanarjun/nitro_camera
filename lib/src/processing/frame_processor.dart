import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../nitro_camera.native.dart' show CameraFrame;

/// A camera frame handed to a [CameraFrameProcessor] handler. The [bytes] are a
/// **copy** owned by the worker isolate (the native zero-copy view cannot cross
/// an isolate boundary), so the handler may keep or transform them freely.
class FrameData {
  final Uint8List bytes;
  final int width;
  final int height;

  /// 0 = YUV_420_888 (bytes = luma plane), 1 = BGRA_8888.
  final int format;
  final int timestamp;
  final int orientation;

  /// Row stride of [bytes]; may exceed `width` (× bytes-per-pixel) due to
  /// hardware alignment. **Walk rows by this, not by width**, or padded frames
  /// decode as garbage.
  final int bytesPerRow;

  /// Whether the frame is horizontally mirrored (front camera).
  final bool isMirrored;

  const FrameData({
    required this.bytes,
    required this.width,
    required this.height,
    this.format = 1,
    this.timestamp = 0,
    this.orientation = 0,
    this.bytesPerRow = 0,
    this.isMirrored = false,
  });

  /// Effective row stride — falls back to a tightly-packed row when the native
  /// stride is unknown (`0`).
  int get effectiveBytesPerRow => bytesPerRow > 0 ? bytesPerRow : width * (format == 1 ? 4 : 1);
}

/// A frame-processing function. It runs on a background isolate, so it **must be
/// a top-level or static function** (a closure capturing state cannot be sent to
/// an isolate). Its return type [R] must be sendable across isolates
/// (primitives, `List`/`Map` of sendables, `TransferableTypedData`, etc.).
typedef FrameHandler<R> = R Function(FrameData frame);

/// Runs ONCE on the worker isolate before any frame is handled — the hook for
/// setting up worker-side state (e.g. instantiating a frame-processor plugin
/// into an isolate global). Must be a top-level or static function; [initArg]
/// must be sendable.
typedef WorkerInitializer = void Function(Object? initArg);

class _Init<R> {
  final SendPort reply;
  final FrameHandler<R> handler;
  final WorkerInitializer? workerInit;
  final Object? workerInitArg;
  const _Init(this.reply, this.handler, [this.workerInit, this.workerInitArg]);
}

/// Per-frame processing statistics, emitted for EVERY processed frame
/// (successful or not) — the basis for scan benchmarking UIs.
class FrameProcessStats {
  /// Wall-clock time the handler took for this frame, in microseconds.
  final int elapsedMicros;

  /// The frame's native timestamp (ms), when known.
  final int frameTimestamp;

  /// Whether the handler produced a result for this frame (non-null return).
  /// Lets UIs benchmark hit latency separately from miss latency.
  final bool success;

  const FrameProcessStats(
    this.elapsedMicros,
    this.frameTimestamp, {
    this.success = false,
  });

  double get elapsedMillis => elapsedMicros / 1000.0;
}

/// Worker → main reply: the handler result plus its timing.
class _Reply<R> {
  final R result;
  final int elapsedMicros;
  final int frameTimestamp;
  const _Reply(this.result, this.elapsedMicros, this.frameTimestamp);
}

/// Wire message: pixel bytes are carried as [TransferableTypedData] so the
/// isolate hand-off *moves* the buffer instead of copying it again.
class _FrameWire {
  final TransferableTypedData bytes;
  final int width;
  final int height;
  final int format;
  final int timestamp;
  final int orientation;
  final int bytesPerRow;
  final bool isMirrored;
  const _FrameWire(this.bytes, this.width, this.height, this.format, this.timestamp, this.orientation, this.bytesPerRow, this.isMirrored);
}

/// Runs a [FrameHandler] on a dedicated background [Isolate], keeping heavy
/// per-frame work off the UI isolate.
///
/// This is the Flutter analogue of vision-camera running frame processors on a
/// separate native thread. Two properties matter for performance:
///  * **Drop-latest backpressure** — if the worker is still busy when a new
///    frame arrives, only the newest pending frame is kept, so the camera
///    pipeline and UI never stall behind slow processing.
///  * **Zero-copy hand-off** — pixels cross the isolate boundary as
///    [TransferableTypedData], so the buffer is copied out of the native frame
///    exactly once (never a second time for the isolate message).
class CameraFrameProcessor<R> {
  final FrameHandler<R> handler;

  /// Optional worker-isolate bootstrap: [workerInit] runs once with
  /// [workerInitArg] on the worker before the first frame. Both must satisfy
  /// isolate-sendability ([workerInit] top-level/static).
  final WorkerInitializer? workerInit;
  final Object? workerInitArg;

  CameraFrameProcessor(this.handler, {this.workerInit, this.workerInitArg});

  Isolate? _isolate;
  SendPort? _toWorker;
  final Completer<void> _ready = Completer<void>();
  final StreamController<R> _out = StreamController<R>.broadcast();
  final StreamController<FrameProcessStats> _stats = StreamController<FrameProcessStats>.broadcast();

  bool _busy = false;
  _FrameWire? _pending;
  bool _disposed = false;

  /// Results emitted by the handler, in completion order.
  Stream<R> get results => _out.stream;

  /// Per-frame handler timing, emitted for every processed frame — feed this
  /// to a benchmarking HUD ("analyze took N ms").
  Stream<FrameProcessStats> get stats => _stats.stream;

  /// Whether [start] has completed and the worker is accepting frames.
  bool get isRunning => _ready.isCompleted && !_disposed;

  /// Spawns the worker isolate. Await this before calling [submit].
  Future<void> start() async {
    if (_disposed) throw StateError('CameraFrameProcessor already disposed');
    final rp = ReceivePort();
    _isolate = await Isolate.spawn(_entry<R>, _Init<R>(rp.sendPort, handler, workerInit, workerInitArg));
    rp.listen((msg) {
      if (msg is SendPort) {
        _toWorker = msg;
        if (!_ready.isCompleted) _ready.complete();
        return;
      }
      // Otherwise it's a handler reply (result + timing).
      _busy = false;
      final reply = msg as _Reply<R>;
      if (!_out.isClosed) _out.add(reply.result);
      if (!_stats.isClosed) {
        _stats.add(
          FrameProcessStats(
            reply.elapsedMicros,
            reply.frameTimestamp,
            success: reply.result != null,
          ),
        );
      }
      final p = _pending;
      if (p != null) {
        _pending = null;
        _dispatch(p);
      }
    });
    await _ready.future;
  }

  /// Submits a frame for processing. If the worker is busy, this frame replaces
  /// any previously-pending frame (drop-latest).
  void submit(FrameData frame) {
    if (_disposed || !_ready.isCompleted) return;
    _enqueue(
      _FrameWire(
        TransferableTypedData.fromList([frame.bytes]),
        frame.width,
        frame.height,
        frame.format,
        frame.timestamp,
        frame.orientation,
        frame.bytesPerRow,
        frame.isMirrored,
      ),
    );
  }

  /// Subscribes to a [CameraFrame] stream, moving each frame's pixels to the
  /// worker with a single copy. Cancel the returned subscription to detach.
  StreamSubscription<CameraFrame> attach(Stream<CameraFrame> frames) {
    return frames.listen((f) {
      if (_disposed || !_ready.isCompleted) return;
      // fromList copies the native view out *now* (while it is valid); the send
      // then transfers ownership without a second copy.
      _enqueue(
        _FrameWire(
          TransferableTypedData.fromList([f.pixels]),
          f.width,
          f.height,
          f.pixelFormat,
          f.timestamp,
          f.orientation,
          f.bytesPerRow,
          f.isMirrored != 0,
        ),
      );
    });
  }

  void _enqueue(_FrameWire wire) {
    if (_busy) {
      _pending = wire; // drop-latest: keep only the newest
      return;
    }
    _dispatch(wire);
  }

  void _dispatch(_FrameWire wire) {
    _busy = true;
    _toWorker!.send(wire);
  }

  /// Kills the worker isolate and closes [results]. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _pending = null;
    if (!_out.isClosed) await _out.close();
    if (!_stats.isClosed) await _stats.close();
  }

  static void _entry<R>(_Init<R> init) {
    final rp = ReceivePort();
    final sw = Stopwatch();
    init.workerInit?.call(init.workerInitArg);
    init.reply.send(rp.sendPort);
    rp.listen((msg) {
      if (msg is _FrameWire) {
        final bytes = msg.bytes.materialize().asUint8List();
        sw
          ..reset()
          ..start();
        final result = init.handler(
          FrameData(
            bytes: bytes,
            width: msg.width,
            height: msg.height,
            format: msg.format,
            timestamp: msg.timestamp,
            orientation: msg.orientation,
            bytesPerRow: msg.bytesPerRow,
            isMirrored: msg.isMirrored,
          ),
        );
        sw.stop();
        init.reply.send(_Reply<R>(result, sw.elapsedMicroseconds, msg.timestamp));
      }
    });
  }
}
