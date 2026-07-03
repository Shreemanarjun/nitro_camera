import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/media_services.dart';
import 'widgets/media_tile.dart';

/// Resolution + duration reported by the player once known (for INFO).
typedef VideoMeta = ({int width, int height, Duration duration});

/// One pager page hosting a media_kit player: center play/pause, seek slider
/// with elapsed/total labels, mute toggle, and a scrub-preview thumbnail
/// above the slider thumb (throttled; degrades to a time bubble).
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.path,
    required this.active,
    this.bottomPadding = 0,
    this.onMeta,
  });

  final String path;

  /// Only the active pager page owns a native player.
  final bool active;

  /// Space reserved for the viewer's action bar below the controls.
  final double bottomPadding;

  final ValueChanged<VideoMeta>? onMeta;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription<Object?>> _subs = [];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _muted = false;
  bool _ready = false;
  int? _videoW, _videoH;
  bool _metaReported = false;

  // Scrubbing state.
  bool _scrubbing = false;
  double _scrubMs = 0;
  Uint8List? _scrubFrame;
  DateTime _lastFrameRequest = DateTime.fromMillisecondsSinceEpoch(0);
  int _frameEpoch = 0;
  int _frameMisses = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) _spinUp();
  }

  @override
  void didUpdateWidget(VideoPlayerPage old) {
    super.didUpdateWidget(old);
    if (widget.active && _player == null) {
      _spinUp();
    } else if (!widget.active && _player != null) {
      _tearDown();
    }
  }

  @override
  void dispose() {
    _tearDown();
    super.dispose();
  }

  void _spinUp() {
    final player = Player();
    final controller = VideoController(player);
    _player = player;
    _controller = controller;

    _subs.addAll([
      player.stream.position.listen((pos) {
        if (!_scrubbing && mounted) setState(() => _position = pos);
      }),
      player.stream.duration.listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
        _reportMeta();
      }),
      player.stream.playing.listen((playing) {
        if (mounted) setState(() => _playing = playing);
      }),
      player.stream.width.listen((w) {
        if (!mounted || w == null) return;
        setState(() {
          _videoW = w;
          _ready = true;
        });
        _reportMeta();
      }),
      player.stream.height.listen((h) {
        if (!mounted || h == null) return;
        _videoH = h;
        _reportMeta();
      }),
    ]);

    player.setPlaylistMode(PlaylistMode.loop);
    if (_muted) player.setVolume(0);
    player.open(Media(widget.path));
  }

  void _tearDown() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player?.dispose();
    _player = null;
    _controller = null;
    _ready = false;
    _playing = false;
  }

  void _reportMeta() {
    final w = _videoW, h = _videoH;
    if (_metaReported || w == null || h == null || _duration == Duration.zero) {
      return;
    }
    _metaReported = true;
    widget.onMeta?.call((width: w, height: h, duration: _duration));
  }

  void _togglePlay() {
    HapticFeedback.selectionClick();
    _player?.playOrPause();
  }

  void _toggleMute() {
    HapticFeedback.selectionClick();
    setState(() => _muted = !_muted);
    _player?.setVolume(_muted ? 0 : 100);
  }

  // ── Scrubbing ───────────────────────────────────────────────────────────────

  void _onScrubStart(double ms) {
    setState(() {
      _scrubbing = true;
      _scrubMs = ms;
      _scrubFrame = null;
      _frameMisses = 0;
    });
    _requestScrubFrame(ms);
  }

  void _onScrubUpdate(double ms) {
    setState(() => _scrubMs = ms);
    _requestScrubFrame(ms);
  }

  Future<void> _onScrubEnd(double ms) async {
    HapticFeedback.selectionClick();
    setState(() {
      _scrubbing = false;
      _scrubFrame = null;
      _position = Duration(milliseconds: ms.round());
    });
    await _player?.seek(Duration(milliseconds: ms.round()));
  }

  /// Throttled (~200ms) preview-frame fetch; after repeated misses the bubble
  /// gracefully degrades to time-only for this scrub session.
  Future<void> _requestScrubFrame(double ms) async {
    if (_frameMisses > 2) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameRequest) <
        const Duration(milliseconds: 200)) {
      return;
    }
    _lastFrameRequest = now;
    final epoch = ++_frameEpoch;
    Uint8List? bytes;
    try {
      bytes = await MediaServices.thumbnails
          .frameAt(widget.path, Duration(milliseconds: ms.round()))
          .timeout(const Duration(milliseconds: 450));
    } catch (_) {
      bytes = null;
    }
    if (!mounted || epoch != _frameEpoch || !_scrubbing) return;
    if (bytes == null) {
      _frameMisses++;
      return;
    }
    setState(() => _scrubFrame = bytes);
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final durationMs =
        _duration.inMilliseconds > 0 ? _duration.inMilliseconds.toDouble() : 1.0;
    final positionMs = (_scrubbing
            ? _scrubMs
            : _position.inMilliseconds.toDouble())
        .clamp(0.0, durationMs);

    return Stack(
      children: [
        // Video surface (poster until the first frame arrives).
        Positioned.fill(
          child: Hero(
            tag: 'media:${widget.path}',
            child: controller != null
                ? Video(
                    controller: controller,
                    controls: NoVideoControls,
                    fit: BoxFit.contain,
                  )
                : _Poster(path: widget.path),
          ),
        ),
        if (controller != null && !_ready)
          Positioned.fill(child: _Poster(path: widget.path)),

        // Tap-anywhere play/pause (kept below the explicit controls).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _togglePlay,
            child: const SizedBox.expand(),
          ),
        ),

        // Center play / pause.
        Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _playing && !_scrubbing ? 0.0 : 1.0,
            child: IgnorePointer(
              ignoring: _playing && !_scrubbing,
              child: GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.25)),
                  ),
                  child: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
        ),

        // Seek controls.
        Positioned(
          left: 0,
          right: 0,
          bottom: widget.bottomPadding,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_scrubbing)
                  _ScrubBubble(
                    frame: _scrubFrame,
                    label: formatClipDuration(
                        Duration(milliseconds: _scrubMs.round())),
                    fraction: durationMs == 0 ? 0 : positionMs / durationMs,
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Text(
                        formatClipDuration(
                            Duration(milliseconds: positionMs.round())),
                        style: _timeStyle,
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 2.5,
                            activeTrackColor: Colors.cyanAccent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            overlayColor:
                                Colors.cyanAccent.withValues(alpha: 0.15),
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14),
                          ),
                          child: Slider(
                            min: 0,
                            max: durationMs,
                            value: positionMs,
                            onChangeStart: _onScrubStart,
                            onChanged: _onScrubUpdate,
                            onChangeEnd: _onScrubEnd,
                          ),
                        ),
                      ),
                      Text(formatClipDuration(_duration), style: _timeStyle),
                      IconButton(
                        tooltip: _muted ? 'Unmute' : 'Mute',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          _muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: _muted ? Colors.white38 : Colors.white,
                          size: 20,
                        ),
                        onPressed: _toggleMute,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const _timeStyle = TextStyle(
    color: Colors.white,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    fontFamily: 'monospace',
  );
}

/// Preview frame (or time-only bubble) floating above the slider thumb.
class _ScrubBubble extends StatelessWidget {
  const _ScrubBubble({
    required this.frame,
    required this.label,
    required this.fraction,
  });

  final Uint8List? frame;
  final String label;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    const bubbleW = 108.0;
    final hasFrame = frame != null;
    return SizedBox(
      height: hasFrame ? 76 : 34,
      child: LayoutBuilder(
        builder: (context, box) {
          final left = (fraction * box.maxWidth - bubbleW / 2)
              .clamp(0.0, (box.maxWidth - bubbleW).clamp(0.0, double.infinity));
          return Stack(
            children: [
              Positioned(
                left: left,
                bottom: 8,
                child: Container(
                  width: bubbleW,
                  height: hasFrame ? 62 : 22,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.cyanAccent, width: 1),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasFrame)
                        Image.memory(frame!,
                            fit: BoxFit.cover, gaplessPlayback: true),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          width: double.infinity,
                          color: Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Cached tile thumbnail as a poster while the player warms up.
class _Poster extends StatelessWidget {
  const _Poster({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: MediaServices.thumbnails.tileFor(path),
      builder: (context, snap) {
        final file = snap.data;
        if (file == null) return const ColoredBox(color: Colors.black);
        return Image.file(
          file,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
        );
      },
    );
  }
}
