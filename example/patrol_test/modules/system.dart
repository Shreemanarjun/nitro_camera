import 'package:patrol/patrol.dart';

/// Native ($.platform) interactions that are NOT part of the app under test
/// (patrol-test-architecture). Permission dialogs are handled inside the
/// Camera module — they are triggered by app actions, so they belong there.
final class System {
  System(this._$);

  final PatrolIntegrationTester _$;

  Future<void> pressHome() => _$.platform.mobile.pressHome();

  Future<void> openAppAgain() => _$.platform.mobile.openApp();
}
