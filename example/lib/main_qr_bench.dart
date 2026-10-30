// QR-scan benchmark — a standalone app for a head-to-head comparison against
// react-native-nitro-zxing's example app (vision-camera + ZXing) on the same
// device. Code lives in lib/features/benchmark/: logic/ (stats, image bench,
// qr-server client), state/ (signal controllers), ui/ (screens + widgets).
//
// Build it as a separate app next to the main example (distinct package id):
//   ORG_GRADLE_PROJECT_appId=dev.shreeman.nitro_qr_bench \
//   ORG_GRADLE_PROJECT_appLabel="QR Bench" \
//   flutter build apk --release -t lib/main_qr_bench.dart
import 'package:flutter/material.dart';

import 'features/benchmark/ui/bench_home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: BenchHomeScreen(),
    ),
  );
}
