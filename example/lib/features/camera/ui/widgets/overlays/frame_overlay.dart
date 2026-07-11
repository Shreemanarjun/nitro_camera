import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera/native.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'dart:ui' as ui;
import '../../../state/camera_store.dart';
import '../common/glass_tooltip.dart';

class FrameOverlay extends StatefulWidget {
  final bool isProcessing;
  const FrameOverlay({super.key, required this.isProcessing});

  @override
  State<FrameOverlay> createState() => _FrameOverlayState();
}

class _FrameOverlayState extends State<FrameOverlay> {
  final ui.Image? _image = null; // reserved (debug preview)
  final _fpsCounter = ValueNotifier<double>(0);
  final _frameCount = ValueNotifier<int>(0);

  /// Smoothed per-frame decode time (ms) — the scan benchmark.
  final _analyzeMs = ValueNotifier<double>(0);

  /// Smoothed decode time of SUCCESSFUL scans only (ms).
  final _hitMs = ValueNotifier<double>(0);
  DateTime? _lastStatAt;
  CodeResult? _lastResult;
  Timer? _resultClearTimer;

  CodeScanner? _scanner;
  StreamSubscription<CodeResult>? _resultSub;
  StreamSubscription<CodeResult>? _detectionSub;
  StreamSubscription<FrameProcessStats>? _statsSub;
  StreamSubscription<CameraFrame>? _assistSub;
  late final void Function() _kindWatchDispose;
  late final void Function() _oneShotWatchDispose;

  // Live highlight state (from raw detections).
  List<double>? _highlightPoints;
  DateTime _highlightAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Auto-assist state.
  bool _torchHint = false;
  int _assistFrameCounter = 0;
  DateTime _lastDetectionAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFocusNudge = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAutoZoom = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _assistTimer;
  bool _oneShotDone = false;

  // Scanner lifecycle guards: signals' subscribe() fires IMMEDIATELY with the
  // current value, so without the change checks initState would spawn three
  // concurrent scanners (direct init + both subscriptions) and leak two worker
  // isolates. The epoch invalidates in-flight inits superseded by a restart.
  int _scannerEpoch = 0;
  late CodeScanKind _scannerKind;
  late bool _scannerOneShot;

  @override
  void initState() {
    super.initState();
    _scannerKind = cameraStore.scanKind.value;
    _scannerOneShot = cameraStore.scanOneShot.value;
    _initScanner(_scannerKind);
    // Restart the worker with the new format family / mode when switched.
    _kindWatchDispose = cameraStore.scanKind.subscribe((kind) {
      if (kind == _scannerKind) return;
      _scannerKind = kind;
      _restartScanner(kind);
    });
    _oneShotWatchDispose = cameraStore.scanOneShot.subscribe((oneShot) {
      if (oneShot == _scannerOneShot) return;
      _scannerOneShot = oneShot;
      _restartScanner(_scannerKind);
    });
    // Focus nudge: if nothing has been detected for a while, refocus center.
    _assistTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !widget.isProcessing) return;
      final now = DateTime.now();
      if (now.difference(_lastDetectionAt).inMilliseconds > 2500 &&
          now.difference(_lastFocusNudge).inSeconds >= 3) {
        _lastFocusNudge = now;
        cameraStore.setFocusPoint(0.5, 0.5);
      }
    });
  }

  /// Spawns a persistent scanning isolate for [kind] and consumes the frame
  /// stream with zero-copy hand-off + drop-latest backpressure ([CodeScanner]).
  Future<void> _initScanner(CodeScanKind kind) async {
    final epoch = ++_scannerEpoch;
    final scanner = CodeScanner(
      kind: kind,
      mode: cameraStore.scanOneShot.value
          ? ScanMode.oneShot
          : ScanMode.continuous,
    );
    await scanner.start(NitroCamera.instance.frameStream);
    if (!mounted || epoch != _scannerEpoch) {
      // Widget gone, or a newer restart superseded this init while its worker
      // was spawning — tear down instead of installing leaked subscriptions.
      await scanner.dispose();
      return;
    }
    _scanner = scanner;
    _oneShotDone = false;
    _resultSub = scanner.results.listen(_onResult);
    _detectionSub = scanner.detections.listen(_onDetection);
    _statsSub = scanner.stats.listen(_onStats);
    // Low-light torch hint: sample the luma stream cheaply on the UI isolate.
    _assistSub = NitroCamera.instance.frameStream.listen(_onAssistFrame);
  }

  /// Raw per-frame detection: drive the live highlight + smart zoom.
  void _onDetection(CodeResult r) {
    if (!mounted || !widget.isProcessing) return;
    _lastDetectionAt = DateTime.now();
    final pts = r.windowPoints;
    if (pts != null && pts.length >= 2) {
      setState(() {
        _highlightPoints = pts;
        _highlightAt = DateTime.now();
      });

      // Smart zoom: symbol much smaller than the window → step zoom in.
      if (pts.length >= 4) {
        var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
        for (var i = 0; i + 1 < pts.length; i += 2) {
          if (pts[i] < minX) minX = pts[i];
          if (pts[i] > maxX) maxX = pts[i];
          if (pts[i + 1] < minY) minY = pts[i + 1];
          if (pts[i + 1] > maxY) maxY = pts[i + 1];
        }
        final span =
            (maxX - minX) > (maxY - minY) ? (maxX - minX) : (maxY - minY);
        final now = DateTime.now();
        final zoom = cameraStore.currentZoom.value;
        if (span < 0.22 &&
            zoom < 2.9 &&
            now.difference(_lastAutoZoom).inSeconds >= 2) {
          _lastAutoZoom = now;
          cameraStore.setZoom((zoom + 1).clamp(1.0, 3.0));
        }
      }
    }
  }

  /// Sparse luma sampling for the low-light torch hint (every 15th frame,
  /// 256 pixels — negligible cost; the pixels view is only valid during the
  /// callback, which is exactly how it's used).
  void _onAssistFrame(CameraFrame f) {
    if (!mounted || !widget.isProcessing) return;
    if (++_assistFrameCounter % 15 != 0) return;
    final px = f.pixels;
    if (px.isEmpty) return;
    var sum = 0;
    final step = px.length > 256 ? px.length ~/ 256 : 1;
    var n = 0;
    for (var i = 0; i < px.length; i += step) {
      sum += px[i];
      n++;
    }
    final mean = sum / n;
    final wantHint = mean < 45 && !cameraStore.torch.value;
    if (wantHint != _torchHint) {
      setState(() => _torchHint = wantHint);
    }
  }

  int _windowFrames = 0;

  /// Every analysed frame (hit or miss): update the scan-FPS + analyze-time
  /// benchmark readouts. FPS is a windowed count (inter-arrival timing lies
  /// when isolate replies arrive in bursts).
  void _onStats(FrameProcessStats s) {
    if (!mounted) return;
    _frameCount.value++;
    _windowFrames++;
    final now = DateTime.now();
    final last = _lastStatAt;
    if (last == null) {
      _lastStatAt = now;
    } else {
      final dt = now.difference(last).inMicroseconds / 1e6;
      if (dt >= 1.0) {
        _fpsCounter.value = _windowFrames / dt;
        _windowFrames = 0;
        _lastStatAt = now;
      }
    }
    _analyzeMs.value = _analyzeMs.value == 0
        ? s.elapsedMillis
        : _analyzeMs.value * 0.8 + s.elapsedMillis * 0.2;
    if (s.success) {
      _hitMs.value = _hitMs.value == 0
          ? s.elapsedMillis
          : _hitMs.value * 0.8 + s.elapsedMillis * 0.2;
    }
  }

  Future<void> _restartScanner(CodeScanKind kind) async {
    await _resultSub?.cancel();
    await _detectionSub?.cancel();
    await _statsSub?.cancel();
    await _assistSub?.cancel();
    await _scanner?.dispose();
    _scanner = null;
    _lastStatAt = null;
    _windowFrames = 0;
    _highlightPoints = null;
    _oneShotDone = false;
    if (!mounted) return;
    await _initScanner(kind);
  }

  void _onResult(CodeResult r) {
    if (!mounted || !widget.isProcessing) return;
    if (_lastResult == null) {
      HapticFeedback.vibrate();
      HapticFeedback.selectionClick();
    }
    final oneShot = cameraStore.scanOneShot.value;
    setState(() {
      _lastResult = r;
      if (oneShot) _oneShotDone = true;
      _resultClearTimer?.cancel();
      if (!oneShot) {
        _resultClearTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _lastResult = null);
        });
      }
    });
  }

  /// One-shot: tap to re-arm for the next scan.
  void _resumeOneShot() {
    _scanner?.resume();
    setState(() {
      _oneShotDone = false;
      _lastResult = null;
      _highlightPoints = null;
    });
  }

  @override
  void dispose() {
    _scannerEpoch++; // invalidate any in-flight _initScanner
    _kindWatchDispose();
    _oneShotWatchDispose();
    _assistTimer?.cancel();
    _resultSub?.cancel();
    _detectionSub?.cancel();
    _statsSub?.cancel();
    _assistSub?.cancel();
    _scanner?.dispose();
    _image?.dispose();
    _fpsCounter.dispose();
    _frameCount.dispose();
    _analyzeMs.dispose();
    _hitMs.dispose();
    _resultClearTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isProcessing) return const SizedBox.shrink();

    return Stack(
      children: [
        IgnorePointer(
          child: Stack(
            children: [
              // 0. Dimmed Background with Scanner Cutout
              const Positioned.fill(child: _TacticalScannerOverlay()),

              // 1. Stats Dashboard (Top Left)
              Positioned(
                left: 20,
                top: 100,
                child: _AnimatedStatsCard(
                  fpsCounter: _fpsCounter,
                  frameCount: _frameCount,
                  analyzeMs: _analyzeMs,
                  hitMs: _hitMs,
                  lastResult: _lastResult?.text,
                ),
              ),

              // 2. Corner Debug View (Small Preview)
              if (_image != null)
                Positioned(
                  right: 20,
                  top: 80,
                  child: Container(
                    width: 90,
                    height: 120,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.cyanAccent.withValues(alpha: 0.1),
                          blurRadius: 10,
                        )
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                        width: 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: RawImage(image: _image, fit: BoxFit.cover),
                    ),
                  ),
                ),

              // 3. QR Viewfinder (Premium Design)
              Center(
                child: _PremiumViewfinder(
                  isScanning: widget.isProcessing,
                  hasResult: _lastResult != null,
                ),
              ),

              // 3b. Live code highlight (raw detections → window-mapped box).
              if (_highlightPoints != null &&
                  DateTime.now().difference(_highlightAt).inMilliseconds < 600)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CodeHighlightPainter(
                      points: _highlightPoints!,
                      windowRect: _decodeWindowRectOnScreen(context),
                    ),
                  ),
                ),

            ],
          ),
        ),

        // 4. Detected Result (Floating Glass Card) — kept OUTSIDE the
        // IgnorePointer above so the copy button actually receives taps. While
        // nested inside the ignore layer its onPressed never fired, so "copy
        // result code" did nothing on both Android and iOS.
        if (_lastResult != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 280),
              child: _QRResultCard(result: _lastResult!),
            ),
          ),

        // 5. Format family selector (QR / 1D / 2D / ALL) — tappable.
        Align(
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.only(top: 400),
            child: Watch((_) => _ScanKindChips(
                  selected: cameraStore.scanKind.value,
                  onChanged: (k) => cameraStore.scanKind.value = k,
                )),
          ),
        ),

        // 6. Quick zoom (small/far codes) — tappable, right of the window.
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Watch((_) => _ZoomChips(
                  current: cameraStore.currentZoom.value,
                  onChanged: cameraStore.setZoom,
                )),
          ),
        ),

        // 7. One-shot / continuous toggle (below the SETTINGS pill).
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 168, right: 16),
            child: Watch((_) {
              final oneShot = cameraStore.scanOneShot.value;
              return GlassTooltip(
                message: 'Scan mode: one-shot / continuous',
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    cameraStore.scanOneShot.value = !oneShot;
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: oneShot
                          ? Colors.cyanAccent
                          : Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.15)),
                    ),
                    child: Text(
                      oneShot ? 'ONE-SHOT' : 'CONTINUOUS',
                      style: TextStyle(
                        color: oneShot ? Colors.black : Colors.white60,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),

        // 8. Low-light auto-assist: pulsing torch suggestion.
        if (_torchHint)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 420),
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  cameraStore.setTorch(true);
                  setState(() => _torchHint = false);
                },
                child: _PulsingChip(
                  icon: Icons.flashlight_on_rounded,
                  label: 'LOW LIGHT — TAP FOR TORCH',
                ),
              ),
            ),
          ),

        // 9. One-shot done: tap anywhere in the window to re-arm.
        if (_oneShotDone)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _resumeOneShot,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 230),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: Colors.cyanAccent.withValues(alpha: 0.5)),
                    ),
                    child: const Text(
                      'TAP TO SCAN AGAIN',
                      style: TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Where the decode window sits ON SCREEN: the stream is cover-fitted and
  /// centered, and the window is a centered square of
  /// [kScannerWindowFraction] × the upright stream's short side.
  Rect _decodeWindowRectOnScreen(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final ctrl = cameraStore.activeController.value;
    var fw = (ctrl?.width ?? 1920).toDouble();
    var fh = (ctrl?.height ?? 1080).toDouble();
    // Upright dims: the preview rotates the landscape stream in portrait.
    if (MediaQuery.of(context).orientation == Orientation.portrait &&
        fw > fh) {
      final t = fw;
      fw = fh;
      fh = t;
    }
    final cover = cameraStore.resizeCover.value;
    final sx = size.width / fw, sy = size.height / fh;
    final scale = cover ? (sx > sy ? sx : sy) : (sx < sy ? sx : sy);
    final side = kScannerWindowFraction * (fw < fh ? fw : fh) * scale;
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );
  }
}

/// Draws the detected code's key points: a bounding quad + corner dots.
class _CodeHighlightPainter extends CustomPainter {
  final List<double> points;
  final Rect windowRect;
  _CodeHighlightPainter({required this.points, required this.windowRect});

  @override
  void paint(Canvas canvas, Size size) {
    final mapped = <Offset>[];
    for (var i = 0; i + 1 < points.length; i += 2) {
      mapped.add(Offset(
        windowRect.left + points[i] * windowRect.width,
        windowRect.top + points[i + 1] * windowRect.height,
      ));
    }
    if (mapped.isEmpty) return;

    final stroke = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    if (mapped.length == 2) {
      // 1D: underline the scanline between the two endpoints.
      canvas.drawLine(mapped[0], mapped[1], stroke);
    } else {
      // 2D: bounding box around all points (finder patterns).
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final p in mapped) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
      final r = Rect.fromLTRB(minX - 12, minY - 12, maxX + 12, maxY + 12);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(10)),
        stroke,
      );
    }
    final dot = Paint()..color = Colors.greenAccent;
    for (final p in mapped) {
      canvas.drawCircle(p, 4, dot);
    }
  }

  @override
  bool shouldRepaint(_CodeHighlightPainter old) =>
      old.points != points || old.windowRect != windowRect;
}

/// A pulsing attention chip (used by the low-light torch hint).
class _PulsingChip extends StatefulWidget {
  final IconData icon;
  final String label;
  const _PulsingChip({required this.icon, required this.label});

  @override
  State<_PulsingChip> createState() => _PulsingChipState();
}

class _PulsingChipState extends State<_PulsingChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.55, end: 1.0).animate(_ctrl),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.amberAccent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.flashlight_on_rounded,
                color: Colors.amberAccent, size: 15),
            const SizedBox(width: 8),
            Text(
              widget.label,
              style: const TextStyle(
                color: Colors.amberAccent,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vertical 1× / 2× / 3× quick-zoom chips for the scanner.
class _ZoomChips extends StatelessWidget {
  final double current;
  final ValueChanged<double> onChanged;
  const _ZoomChips({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final z in const [1.0, 2.0, 3.0])
                GlassTooltip(
                  message: 'Zoom ${z.toInt()}×',
                  preferBelow: false,
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onChanged(z);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      width: 40,
                      height: 40,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      decoration: BoxDecoration(
                        color: (current - z).abs() < 0.35
                            ? Colors.cyanAccent
                            : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${z.toInt()}×',
                          style: TextStyle(
                            color: (current - z).abs() < 0.35
                                ? Colors.black
                                : Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// QR / 1D / 2D / ALL selector chips shown under the viewfinder.
class _ScanKindChips extends StatelessWidget {
  final CodeScanKind selected;
  final ValueChanged<CodeScanKind> onChanged;
  const _ScanKindChips({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final kind in CodeScanKind.values)
                GlassTooltip(
                  message: switch (kind) {
                    CodeScanKind.qr => 'QR codes only',
                    CodeScanKind.oneD => 'Linear (1D) barcodes',
                    CodeScanKind.twoD => 'Matrix (2D) codes',
                    CodeScanKind.postal => 'Postal codes',
                    CodeScanKind.pharma => 'Pharmacode',
                    CodeScanKind.all => 'All code formats',
                  },
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onChanged(kind);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: kind == selected
                            ? Colors.cyanAccent
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        kind.label,
                        style: TextStyle(
                          color:
                              kind == selected ? Colors.black : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnimatedStatsCard extends StatelessWidget {
  final ValueNotifier<double> fpsCounter;
  final ValueNotifier<int> frameCount;
  final ValueNotifier<double> analyzeMs;
  final ValueNotifier<double> hitMs;
  final String? lastResult;

  const _AnimatedStatsCard({
    required this.fpsCounter,
    required this.frameCount,
    required this.analyzeMs,
    required this.hitMs,
    this.lastResult,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatItem(
                icon: Icons.bolt,
                label: "STREAM",
                value: ValueListenableBuilder<double>(
                  valueListenable: fpsCounter,
                  builder: (ctx, v, _) => Text("${v.toInt()} FPS", style: _valStyle),
                ),
                color: Colors.cyanAccent,
              ),
              const SizedBox(height: 12),
              _StatItem(
                icon: Icons.timer_outlined,
                label: "ANALYZE",
                value: ValueListenableBuilder<double>(
                  valueListenable: analyzeMs,
                  builder: (ctx, v, _) => Text(
                    v == 0 ? "—" : "${v.toStringAsFixed(1)} ms",
                    style: _valStyle.copyWith(
                      color: v == 0
                          ? Colors.white38
                          : v < 20
                              ? Colors.greenAccent
                              : v < 50
                                  ? Colors.amberAccent
                                  : Colors.redAccent,
                    ),
                  ),
                ),
                color: Colors.cyanAccent,
              ),
              const SizedBox(height: 12),
              _StatItem(
                icon: Icons.check_circle_outline,
                label: "HIT AVG",
                value: ValueListenableBuilder<double>(
                  valueListenable: hitMs,
                  builder: (ctx, v, _) => Text(
                    v == 0 ? "—" : "${v.toStringAsFixed(1)} ms",
                    style: _valStyle.copyWith(
                      color: v == 0 ? Colors.white38 : Colors.greenAccent,
                    ),
                  ),
                ),
                color: Colors.greenAccent,
              ),
              const SizedBox(height: 12),
              _StatItem(
                icon: Icons.numbers,
                label: "FRAMES",
                value: ValueListenableBuilder<int>(
                  valueListenable: frameCount,
                  builder: (ctx, v, _) => Text(v.toString(), style: _valStyle),
                ),
                color: Colors.white70,
              ),
              const SizedBox(height: 12),
              _StatItem(
                icon: Icons.qr_code_scanner,
                label: "SCANNER",
                value: Text(lastResult != null ? "FOUND" : "SCANNING", style: _valStyle.copyWith(
                  color: lastResult != null ? Colors.greenAccent : Colors.white38,
                )),
                color: lastResult != null ? Colors.greenAccent : Colors.white24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _valStyle = TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900, fontFamily: 'monospace');
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget value;
  final Color color;
  const _StatItem({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            value,
          ],
        ),
      ],
    );
  }
}

class _PremiumViewfinder extends StatelessWidget {
  final bool isScanning;
  final bool hasResult;

  const _PremiumViewfinder({required this.isScanning, required this.hasResult});

  @override
  Widget build(BuildContext context) {
    final color = hasResult ? Colors.greenAccent : Colors.cyanAccent;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.9, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.elasticOut,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 280,
            height: 280,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(48),
              border: Border.all(color: color.withValues(alpha: 0.1), width: 2),
              boxShadow: isScanning ? [
                 BoxShadow(
                   color: color.withValues(alpha: 0.05),
                   blurRadius: 40,
                   spreadRadius: 10,
                 )
              ] : null,
            ),
            child: Stack(
              children: [
                ...List.generate(4, (i) => Positioned(
                  top: i < 2 ? -2 : null,
                  bottom: i >= 2 ? -2 : null,
                  left: i % 2 == 0 ? -2 : null,
                  right: i % 2 != 0 ? -2 : null,
                  child: _Corner(index: i, color: color),
                )),
                if (isScanning && !hasResult) const _ScanningBeam(),
                if (hasResult)
                  Center(
                    child: _PulseCircle(color: Colors.greenAccent),
                  ),
                if (hasResult) ...[
                  const _SuccessFlash(),
                  const Center(child: Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 60)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Corner extends StatelessWidget {
  final int index;
  final Color color;
  const _Corner({required this.index, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 45,
      height: 45,
      decoration: BoxDecoration(
        border: Border(
          top: index < 2 ? BorderSide(color: color, width: 5) : BorderSide.none,
          bottom: index >= 2 ? BorderSide(color: color, width: 5) : BorderSide.none,
          left: index % 2 == 0 ? BorderSide(color: color, width: 5) : BorderSide.none,
          right: index % 2 != 0 ? BorderSide(color: color, width: 5) : BorderSide.none,
        ),
        borderRadius: BorderRadius.only(
          topLeft: index == 0 ? const Radius.circular(22) : Radius.zero,
          topRight: index == 1 ? const Radius.circular(22) : Radius.zero,
          bottomLeft: index == 2 ? const Radius.circular(22) : Radius.zero,
          bottomRight: index == 3 ? const Radius.circular(22) : Radius.zero,
        ),
      ),
    );
  }
}

class _PulseCircle extends StatelessWidget {
  final Color color;
  const _PulseCircle({required this.color});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.5, end: 1.2),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Container(
        width: 200 * value,
        height: 200 * value,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: (1.0 - value).clamp(0, 1)),
            width: 3,
          ),
        ),
      ),
    );
  }
}

class _ScanningBeam extends StatefulWidget {
  const _ScanningBeam();
  @override
  State<_ScanningBeam> createState() => _ScanningBeamState();
}

class _ScanningBeamState extends State<_ScanningBeam> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500))..repeat(reverse: true);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Positioned(
        top: 260 * Curves.easeInOut.transform(_ctrl.value),
        left: 30,
        right: 30,
        child: Container(
          height: 3,
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.6), blurRadius: 20, spreadRadius: 2)
            ],
            gradient: LinearGradient(colors: [
              Colors.cyanAccent.withValues(alpha: 0),
              Colors.cyanAccent,
              Colors.cyanAccent.withValues(alpha: 0),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SuccessFlash extends StatelessWidget {
  const _SuccessFlash();
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, value, _) => Container(
        decoration: BoxDecoration(
          color: Colors.greenAccent.withValues(alpha: (1.0 - value) * 0.2),
          borderRadius: BorderRadius.circular(48),
        ),
      ),
    );
  }
}

class _TacticalScannerOverlay extends StatelessWidget {
  const _TacticalScannerOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _ScannerHolePainter(),
    );
  }
}

class _ScannerHolePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(0, 0, size.width, size.height);
    final hole = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 280,
      height: 280,
    );
    final rhole = RRect.fromRectAndRadius(hole, const Radius.circular(48));

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect),
        Path()..addRRect(rhole),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _QRResultCard extends StatelessWidget {
  final CodeResult result;
  const _QRResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutQuart,
      builder: (context, value, child) => Transform.translate(
        offset: Offset(0, 40 * (1 - value)),
        child: Opacity(opacity: value.clamp(0, 1), child: child),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.3), width: 2),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.greenAccent, size: 28),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [
                            result.format.name.toUpperCase(),
                            if (result.isGs1) 'GS1',
                            if (result.isbn != null) 'ISBN',
                          ].join('  ·  '),
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          result.text,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                          // Wrap to two lines before ellipsizing so typical
                          // payloads (URLs, GS1 AI strings) aren't clipped.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: result.text));
                      HapticFeedback.selectionClick();
                    },
                    icon: const Icon(Icons.copy_rounded, color: Colors.white38, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
