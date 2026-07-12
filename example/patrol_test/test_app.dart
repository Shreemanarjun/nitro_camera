import 'package:patrol/patrol.dart';

import '../integration_test/support/harness.dart'
    show installSemanticsFlakeFilter;
import 'modules/api_clients.dart';
import 'modules/modules.dart';
import 'modules/system.dart';

typedef TestAppCallback =
    Future<void> Function(
      PatrolIntegrationTester $,
      Modules modules,
      System system,
      ApiClients apiClients,
    );

/// Project-standard Patrol wrapper: every test gets the Modules / System /
/// ApiClients trio (patrol-test-architecture). One test per file.
void testApp(String description, TestAppCallback body) {
  // Same ColorOS SemanticsHandle flake filter as the plain suites — Patrol's
  // binding runs the identical end-of-test verifier. Idempotent.
  installSemanticsFlakeFilter();
  patrolTest(description, ($) async {
    await body($, Modules($), System($), ApiClients());
  });
}
