import 'package:flutter_test/flutter_test.dart'
    show expect, isNull, isNotNull, isNot, isTrue;
import 'package:nitro_camera/nitro_camera.dart';

import 'package:nitro_camera_example/features/camera/state/camera_store.dart';

import '../../integration_test/support/harness.dart' as harness;
import 'module.dart';

/// Boot + session-lifecycle module: mounts the example app through the SHARED
/// harness and walks the runtime permission dialogs natively. With the test
/// orchestrator clearing package data, EVERY test starts permissionless — the
/// app's grant flow fires the CAMERA dialog then the RECORD_AUDIO dialog, and
/// both are accepted via $.platform (no adb pre-grant needed; this kills the
/// ColorOS pm-grant workaround).
final class Camera extends Module {
  Camera(super.$);

  /// The live session controller (only valid after [openAppToPreview]).
  CameraController get controller => cameraStore.activeController.value!;

  /// Starts the app and reaches a running preview.
  ///
  /// alwaysRequest: the request + native-grant flow runs UNCONDITIONALLY (even
  /// if the OS already reports the permission granted), so Patrol always drives
  /// the grant — deterministic and independent of any retained state.
  Future<void> openAppToPreview() {
    return harness.bootApp(
      $.tester,
      alwaysRequest: true,
      // acceptPermissionDialogs (on the base Module) grants BOTH the CAMERA and
      // RECORD_AUDIO dialogs the plugin's single requestPermissions call raises.
      grantPermissionNatively: acceptPermissionDialogs,
    );
  }

  Future<void> verifyPreviewHealthy() async {
    expect(cameraStore.status.value, CameraStatus.running);
    expect(cameraStore.activeController.value, isNotNull);
    expect(cameraStore.activeTextureId.value, isNotNull);
    expect(cameraStore.activeTextureId.value, isNot(0));
    expect(cameraStore.errorMessage.value, isNull);
    expect(controller.getSessionState().running, isTrue);
  }
}
