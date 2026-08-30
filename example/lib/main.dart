import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nitro/nitro.dart';

import 'features/camera/state/camera_store.dart';
import 'features/camera/ui/camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock the camera control UI to portrait for a consistent layout — the
  // preview and captures handle device rotation themselves (native renderer +
  // recording orientation), so the chrome never needs to reflow.
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
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
