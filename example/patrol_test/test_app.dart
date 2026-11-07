import 'dart:io';

import 'package:patrol/patrol.dart';
import 'package:path_provider/path_provider.dart';

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
    try {
      await body($, Modules($), System($), ApiClients());
    } finally {
      await _logPeakMemory(description);
    }
  });
}

/// Appends this test's peak RSS to Documents/patrol_memory.log (pull it with
/// `xcrun devicectl device copy from --domain-type appDataContainer`), so a
/// memory-limit kill can be traced to the test that grew.
Future<void> _logPeakMemory(String description) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final mb = ProcessInfo.maxRss >> 20;
    await File('${dir.path}/patrol_memory.log').writeAsString(
      '${DateTime.now().toIso8601String()} ${mb}MB $description\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object {
    // Diagnostics only — never fail a test over it.
  }
}
