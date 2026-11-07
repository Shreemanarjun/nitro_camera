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
///
/// [tags]: `'slow'` marks soak/perf tests (≥ ~25 s) so day-to-day runs can
/// skip them with `--exclude-tags=slow`.
void testApp(String description, TestAppCallback body, {Object? tags}) {
  // Same ColorOS SemanticsHandle flake filter as the plain suites — Patrol's
  // binding runs the identical end-of-test verifier. Idempotent.
  installSemanticsFlakeFilter();
  patrolTest(description, tags: tags, ($) async {
    await body($, Modules($), System($), ApiClients());
  });
}
