// Focused on-device validation of the custom NATIVE detector plugin
// (meanLuma), registered from AppDelegate / MainActivity via the open
// NitraDetectors registry. High-speed and manual focus/exposure are validated
// by api_surface_test (tests 9b and 4); this isolates meanLuma so a camera-heavy
// step (and the flaky wireless link) can't block reaching it.
//
//   flutter test integration_test/new_features_test.dart -d <serial>   (USB)
//   or xcodebuild test over CoreDevice (wireless iOS) — see RunnerTests.swift.

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:integration_test/integration_test.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import 'support/harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installSemanticsFlakeFilter();

  CameraController ctrl() => cameraStore.activeController.value!;

  testWidgets(
    'custom native detector meanLuma delivers luminance results',
    semanticsEnabled: false,
    (tester) async {
      await bootApp(tester);
      final c = ctrl();

      // meanLuma is registered by the host app (AppDelegate / MainActivity) via
      // NitraDetectors.register — the open native-plugin registry. It emits mean
      // scene luminance (0..255) on every frame, so a real camera yields
      // assertable results.
      final results = <Map<String, dynamic>>[];
      final sub = c.nativeDetections.listen(results.add);
      c.setNativeDetector('meanLuma');
      for (var i = 0; i < 20 && results.isEmpty; i++) {
        await pumpFor(tester, const Duration(milliseconds: 500));
      }
      c.setNativeDetector('');
      await sub.cancel();

      expect(
        results,
        isNotEmpty,
        reason: 'meanLuma custom native detector delivered results',
      );
      final r = results.last;
      expect(r['detector'], 'meanLuma');
      final list = (r['results'] as List).cast<Map<String, dynamic>>();
      expect(list, isNotEmpty);
      expect((list.first['luma'] as num).toInt(), inInclusiveRange(0, 255));

      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(cameraStore.status.value, CameraStatus.running);
      expect(cameraStore.errorMessage.value, isNull);
    },
  );
}
