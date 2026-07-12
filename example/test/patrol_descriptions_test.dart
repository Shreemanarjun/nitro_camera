import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// EARLY-CATCH guard (runs in plain `flutter test`, no device, ~instant).
///
/// The AndroidX Test Orchestrator writes a per-test output file NAMED AFTER the
/// test description. A `/` (or `\`) in the description makes `Context.makeFilename`
/// throw "contains a path separator", which crashes the ENTIRE orchestrator
/// process — aborting the whole Patrol run with a useless "Gradle code 1" and
/// zero reported failures. That cost a full 2-minute on-device run to diagnose;
/// this test fails in milliseconds instead.
///
/// Keep Patrol `testApp('...')` descriptions free of path separators.
void main() {
  test('no Patrol test description contains a path separator', () {
    final dir = Directory('patrol_test');
    if (!dir.existsSync()) {
      fail('patrol_test/ not found — run from the example package root');
    }

    // testApp('<description>', ... — capture the single-quoted description.
    final re = RegExp(r"testApp\(\s*'([^']*)'");
    final offenders = <String>[];
    var scanned = 0;

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
      final src = entity.readAsStringSync();
      for (final m in re.allMatches(src)) {
        scanned++;
        final desc = m.group(1)!;
        if (desc.contains('/') || desc.contains(r'\')) {
          offenders.add('${entity.path}: "$desc"');
        }
      }
    }

    expect(
      scanned,
      greaterThan(0),
      reason: 'no testApp(...) descriptions found — regex or layout drift?',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'These descriptions contain a path separator and will crash the '
          'AndroidX orchestrator (rename, e.g. "on/off" -> "on and off"):\n'
          '${offenders.join('\n')}',
    );
  });
}
