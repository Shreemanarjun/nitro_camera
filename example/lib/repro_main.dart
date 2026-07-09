// TEMPORARY crash-reproduction entrypoint (diagnostic only — delete after use).
//
// Reproduces the field report: open camera -> frame processing on -> view a
// recorded video via media_kit -> switch to the ultra-wide lens -> crash.
// Built in PROFILE mode so it can launch from the home screen / agent-device
// (debug builds are blocked outside flutter tooling on iOS 14+). Drives itself
// from Dart; the only manual/automated step is accepting the permission dialog.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nitro/nitro.dart';

import 'features/camera/processors/luminance_processor.dart';
import 'features/camera/state/camera_store.dart';
import 'features/camera/ui/camera_screen.dart';

void _log(String m) {
  final line = 'CRASH_REPRO: $m';
  // ignore: avoid_print
  print(line);
  developer.log(line, name: 'CRASH_REPRO');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  NitroConfig.instance.enable(
    slowCallThresholdMs: 200,
    level: NitroLogLevel.verbose,
  );
  NitroRuntime.init(isolatePoolSize: Platform.numberOfProcessors);
  Future.delayed(Duration.zero, () => cameraStore.init());
  runApp(const _ReproApp());
}

class _ReproApp extends StatefulWidget {
  const _ReproApp();
  @override
  State<_ReproApp> createState() => _ReproAppState();
}

class _ReproAppState extends State<_ReproApp> {
  Player? _player;
  VideoController? _videoController;
  bool _showVideo = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _waitUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 25),
    required String what,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        _log('TIMEOUT waiting for $what');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _run() async {
    _log('start');

    // Permission (agent-device accepts the system dialog).
    if (cameraStore.cameraPermission.value != 1) {
      _log('requesting camera permission');
      unawaited(cameraStore.grantPermission());
      await _waitUntil(() => cameraStore.cameraPermission.value == 1,
          timeout: const Duration(seconds: 90), what: 'camera permission');
    }

    await _waitUntil(
        () =>
            cameraStore.status.value == CameraStatus.running &&
            (cameraStore.activeController.value?.isInitialized ?? false),
        what: 'camera running');
    _log('camera running tid=${cameraStore.activeTextureId.value} '
        'device=${cameraStore.currentDevice.value?.name}');

    // Frame processing ON (LUMA).
    cameraStore.setFrameProcessor(luminanceProcessor);
    await _waitUntil(() => luminanceProcessor.framesProcessed.value > 0,
        what: 'first luma frame');
    _log('luma frames=${luminanceProcessor.framesProcessed.value}');

    // Record a short clip so we have a real file to play via media_kit.
    _log('recording 2s clip');
    await cameraStore.toggleRecording();
    await Future<void>.delayed(const Duration(seconds: 2));
    await cameraStore.toggleRecording();
    await _waitUntil(
        () =>
            (cameraStore.lastCapturedPath.value?.isNotEmpty ?? false) &&
            cameraStore.isLastCapturedVideo.value,
        what: 'recorded video path');
    final videoPath = cameraStore.lastCapturedPath.value;
    _log('recorded video=$videoPath');

    // media_kit Player + VideoController (mimics gallery playback) — registers
    // a Flutter texture and fires media_kit's NativeReferenceHolder.
    final player = Player();
    final vc = VideoController(player);
    _player = player;
    _videoController = vc;
    if (mounted) setState(() => _showVideo = true);
    if (videoPath != null && videoPath.isNotEmpty) {
      await player.open(Media(videoPath));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    _log('media_kit up id=${vc.id.value}');

    // Back to camera (keep the player/controller alive → its texture stays
    // registered), then SWITCH TO ULTRA-WIDE with frame processing on.
    if (mounted) setState(() => _showVideo = false);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final devices = cameraStore.devices.value;
    _log('devices=${devices.map((d) => "${d.name}|lens${d.lensType}|pos${d.position}").toList()}');
    final uw = devices.where((d) => d.lensType == 2).toList();
    if (uw.isEmpty) {
      _log('NO ultra-wide device found — aborting');
      return;
    }
    _log('SWITCHING to ultra-wide: ${uw.first.name}');
    await cameraStore.selectDevice(uw.first);
    await _waitUntil(
        () =>
            cameraStore.status.value == CameraStatus.running &&
            (cameraStore.activeController.value?.isInitialized ?? false),
        timeout: const Duration(seconds: 25),
        what: 'ultra-wide running');
    _log('SWITCHED tid=${cameraStore.activeTextureId.value}');
    await Future<void>.delayed(const Duration(seconds: 4));
    _log('DONE — no crash observed');
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Stack(
        children: [
          const CameraScreen(),
          if (_showVideo && _videoController != null)
            Positioned.fill(
              child: Video(
                controller: _videoController!,
                controls: NoVideoControls,
              ),
            ),
        ],
      ),
    );
  }
}
