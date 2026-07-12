import 'dart:async';
import 'dart:typed_data';

import 'package:nitro_camera/nitro_camera.dart';

/// Aggregate statistics over a window of camera frames — the basis for
/// image-level assertions (HDR / low-light dynamic range, "preview isn't
/// black/stuck") and preview-stability checks (FPS, stall gaps).
///
/// Luma is read directly from the frame:
///  * pixelFormat 0 (YUV_420): plane-0 byte == luma.
///  * pixelFormat 1 (BGRA_8888): luma = 0.114B + 0.587G + 0.299R.
/// Row stride ([CameraFrame.bytesPerRow]) is honoured; pixels are subsampled
/// (every [stride]th) so the compute stays cheap inside the zero-copy borrow.
class FrameStreamReport {
  /// Frames observed in the window.
  final int frameCount;

  /// Frames per second, from the elapsed wall-clock over the window.
  final double fps;

  /// Largest gap between consecutive frame timestamps (ms) — a stall detector.
  /// Uses the frames' own timestamps (stream cadence), not Dart scheduling.
  final int maxGapMs;

  /// Mean luma (0..255) across all sampled pixels of all frames.
  final double meanLuma;

  /// 5th and 95th percentile luma across the aggregate histogram.
  final int p5;
  final int p95;

  /// The dimmest and brightest per-frame mean luma seen (degenerate-frame
  /// detector: a stuck/black preview reads ~0, a blown preview ~255).
  final double minFrameMean;
  final double maxFrameMean;

  const FrameStreamReport({
    required this.frameCount,
    required this.fps,
    required this.maxGapMs,
    required this.meanLuma,
    required this.p5,
    required this.p95,
    required this.minFrameMean,
    required this.maxFrameMean,
  });

  /// Dynamic-range proxy: spread between the 95th and 5th luma percentiles.
  int get dynamicRange => p95 - p5;

  /// True when every frame carried real image content — none was a
  /// degenerate all-black or all-white frame (the pixel-level "preview is
  /// actually showing something / not stuck" check).
  bool get allFramesValid => minFrameMean > 3.0 && maxFrameMean < 252.0;

  @override
  String toString() =>
      'FrameStreamReport(n=$frameCount, fps=${fps.toStringAsFixed(1)}, '
      'maxGap=${maxGapMs}ms, meanLuma=${meanLuma.toStringAsFixed(1)}, '
      'range=$dynamicRange [$p5..$p95], '
      'frameMean=[${minFrameMean.toStringAsFixed(1)}..'
      '${maxFrameMean.toStringAsFixed(1)}])';
}

/// Collects [FrameStreamReport]s by listening to a [CameraController]'s
/// frame stream. Enable frame processing on the controller first (or pass a
/// stream directly).
class FrameStatsCollector {
  FrameStatsCollector({this.stride = 8});

  /// Pixel subsample step (both axes). 8 keeps ~1/64 of pixels — plenty for
  /// stable statistics, cheap enough to run every frame.
  final int stride;

  final Int64List _hist = Int64List(256);
  int _frameCount = 0;
  int _firstTs = 0;
  int _lastTs = 0;
  int _maxGapMs = 0;
  double _minFrameMean = 255.0;
  double _maxFrameMean = 0.0;
  final Stopwatch _wall = Stopwatch();
  StreamSubscription<CameraFrame>? _sub;

  /// Subscribes to [stream] and accumulates until [stop].
  void attach(Stream<CameraFrame> stream) {
    _wall.start();
    _sub = stream.listen(_onFrame);
  }

  void _onFrame(CameraFrame f) {
    final px = f.pixels;
    final w = f.width, h = f.height;
    if (w <= 0 || h <= 0 || px.isEmpty) return;
    final isBgra = f.pixelFormat == 1;
    final rowStride = f.bytesPerRow > 0 ? f.bytesPerRow : (isBgra ? w * 4 : w);

    var frameSum = 0;
    var frameSamples = 0;
    for (var y = 0; y < h; y += stride) {
      final row = y * rowStride;
      for (var x = 0; x < w; x += stride) {
        final int luma;
        if (isBgra) {
          final i = row + x * 4;
          if (i + 2 >= px.length) continue;
          luma = (0.114 * px[i] + 0.587 * px[i + 1] + 0.299 * px[i + 2])
              .round();
        } else {
          final i = row + x;
          if (i >= px.length) continue;
          luma = px[i];
        }
        final clamped = luma < 0 ? 0 : (luma > 255 ? 255 : luma);
        _hist[clamped]++;
        frameSum += clamped;
        frameSamples++;
      }
    }
    if (frameSamples == 0) return;

    final frameMean = frameSum / frameSamples;
    if (frameMean < _minFrameMean) _minFrameMean = frameMean;
    if (frameMean > _maxFrameMean) _maxFrameMean = frameMean;

    // Inter-frame gap from the stream's own timestamps.
    final ts = f.timestamp;
    if (_frameCount == 0) {
      _firstTs = ts;
    } else if (ts > _lastTs && _lastTs > 0) {
      final gap = ts - _lastTs;
      if (gap > _maxGapMs) _maxGapMs = gap;
    }
    _lastTs = ts;
    _frameCount++;
  }

  /// Stops listening and returns the aggregate report.
  Future<FrameStreamReport> stop() async {
    _wall.stop();
    await _sub?.cancel();
    _sub = null;

    var total = 0;
    var weighted = 0;
    for (var i = 0; i < 256; i++) {
      total += _hist[i];
      weighted += _hist[i] * i;
    }
    final meanLuma = total == 0 ? 0.0 : weighted / total;

    int percentile(double frac) {
      if (total == 0) return 0;
      final target = (total * frac).floor();
      var acc = 0;
      for (var i = 0; i < 256; i++) {
        acc += _hist[i];
        if (acc >= target) return i;
      }
      return 255;
    }

    final elapsedSec = _wall.elapsedMilliseconds / 1000.0;
    final fps = elapsedSec > 0 ? _frameCount / elapsedSec : 0.0;
    // Timestamp span (if present) is a better FPS source than wall clock.
    final tsSpanSec = (_lastTs > _firstTs)
        ? (_lastTs - _firstTs) / 1000.0
        : 0.0;
    final tsFps = tsSpanSec > 0 ? (_frameCount - 1) / tsSpanSec : 0.0;

    return FrameStreamReport(
      frameCount: _frameCount,
      fps: tsFps > 1.0 ? tsFps : fps,
      maxGapMs: _maxGapMs,
      meanLuma: meanLuma,
      p5: percentile(0.05),
      p95: percentile(0.95),
      minFrameMean: _frameCount == 0 ? 0.0 : _minFrameMean,
      maxFrameMean: _maxFrameMean,
    );
  }
}
