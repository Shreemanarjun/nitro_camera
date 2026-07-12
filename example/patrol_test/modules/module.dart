import 'package:patrol/patrol.dart';

import '../../integration_test/support/harness.dart' as harness;

/// Base class for feature modules (patrol-test-architecture).
///
/// The pump helpers delegate to the SHARED on-device harness
/// (integration_test/support/harness.dart) so both suite styles poll camera
/// state identically — camera state is asynchronous NATIVE state (HAL
/// sessions, FFI streams) that widget-settle heuristics cannot observe.
abstract base class Module {
  Module(this.$);

  final PatrolIntegrationTester $;

  /// Pumps real frames until [condition] holds, failing after [timeout].
  Future<void> pumpUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 15),
    required String reason,
  }) =>
      harness.pumpUntil($.tester, condition, timeout: timeout, reason: reason);

  /// Lets the app run (real time + frames) for [duration].
  Future<void> pumpFor(Duration duration) =>
      harness.pumpFor($.tester, duration);

  /// Accepts every native permission dialog the request flow raises, using the
  /// documented guard: wait for a dialog to be VISIBLE, then grant, and stop as
  /// soon as none appears (a blind grant call hangs when no dialog shows).
  ///
  /// [maxDialogs] defaults to 2 because the plugin's native
  /// `requestCameraPermission()` asks for CAMERA **and** RECORD_AUDIO in a
  /// single `requestPermissions` call — two sequential system dialogs — and its
  /// result callback only fires once BOTH are answered. Accepting only the
  /// first leaves the request awaiting forever (the camera_view_widget_test
  /// hang).
  Future<void> acceptPermissionDialogs({int maxDialogs = 2}) async {
    for (var i = 0; i < maxDialogs; i++) {
      final visible = await $.platform.mobile.isPermissionDialogVisible(
        timeout: const Duration(seconds: 5),
      );
      if (!visible) break;
      await Future<void>.delayed(const Duration(seconds: 1));
      await $.platform.mobile.grantPermissionWhenInUse();
      await $.tester.pump();
    }
  }
}
