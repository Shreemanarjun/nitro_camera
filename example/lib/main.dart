import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nitro/nitro.dart';

import 'features/camera/state/camera_store.dart';
import 'features/camera/ui/camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  NitroConfig.instance.enable(
    slowCallThresholdMs: 200,
    level: NitroLogLevel.verbose,
  );
  NitroRuntime.init(isolatePoolSize: Platform.numberOfProcessors);

  // Pre-warm camera initialization in background after first frame draw
  Future.delayed(Duration.zero, () => cameraStore.init());

  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: CameraScreen()),
  );
}
