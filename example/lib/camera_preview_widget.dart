import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// A high-performance, lifecycle-managed camera preview widget.
/// Automatically handles opening and closing the camera session.
class NitraCameraPreview extends StatefulWidget {
  final CameraDevice device;
  final int width;
  final int height;
  final int fps;
  final bool enableAudio;
  final String? filterShader;
  final Function(CameraFrame)? onFrame;
  final Function(int textureId)? onStarted;
  final Function(String error)? onError;

  const NitraCameraPreview({
    super.key,
    required this.device,
    this.width = 1280,
    this.height = 720,
    this.fps = 30,
    this.enableAudio = false,
    this.filterShader,
    this.onFrame,
    this.onStarted,
    this.onError,
  });

  @override
  State<NitraCameraPreview> createState() => _NitraCameraPreviewState();
}

class _NitraCameraPreviewState extends State<NitraCameraPreview> {
  int? _textureId;
  bool _isOpening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  @override
  void didUpdateWidget(NitraCameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.id != widget.device.id ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height ||
        oldWidget.fps != widget.fps) {
      _restartCamera();
    } else if (oldWidget.filterShader != widget.filterShader) {
      _applyFilter();
    }
  }

  @override
  void dispose() {
    _closeCamera();
    super.dispose();
  }

  Future<void> _startCamera() async {
    if (_isOpening) return;
    await _openCameraInternal();
  }

  Future<void> _openCameraInternal() async {
    setState(() {
      _isOpening = true;
      _error = null;
    });

    try {
      final id = await NitroCamera.instance.openCamera(
        widget.device.id,
        widget.width, widget.height, widget.fps, 
        widget.enableAudio ? 1 : 0,
      );
      
      if (!mounted) {
        await NitroCamera.instance.closeCamera(id);
        return;
      }

      setState(() {
        _textureId = id;
        _isOpening = false;
      });

      if (widget.filterShader != null) {
        await NitroCamera.instance.setFilterShader(id, widget.filterShader!);
      }

      widget.onStarted?.call(id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isOpening = false;
        });
      }
      widget.onError?.call(e.toString());
    } finally {
       if (mounted) setState(() => _isOpening = false);
    }
  }

  Future<void> _closeCamera() async {
    final id = _textureId;
    if (id != null) {
      _textureId = null;
      try {
        await NitroCamera.instance.closeCamera(id);
      } catch (e) {
        debugPrint("Dispose error: $e");
      }
    }
  }

  Future<void> _restartCamera() async {
    if (_isOpening) return;
    setState(() {
      _textureId = null;
      _error = null;
    });
    await _closeCamera();
    if (mounted) await _openCameraInternal();
  }

  Future<void> _applyFilter() async {
    final id = _textureId;
    if (id != null && widget.filterShader != null) {
      await NitroCamera.instance.setFilterShader(id, widget.filterShader!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            TextButton(onPressed: _startCamera, child: const Text("RETRY")),
          ],
        ),
      );
    }

    if (_textureId == null) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    // Determine preview aspect ratio from device if possible
    // Note: Most mobile sensors are 4:3 or 16:9
    final double aspectRatio = widget.device.position == 1 ? 0.75 : 0.75; // Front/Back portrait

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Texture(textureId: _textureId!),
    );
  }
}
