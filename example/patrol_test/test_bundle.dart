// GENERATED CODE - DO NOT MODIFY BY HAND AND DO NOT COMMIT TO VERSION CONTROL
// ignore_for_file: type=lint, invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:patrol/src/platform/contracts/contracts.dart';
import 'package:test_api/src/backend/invoker.dart';

// START: GENERATED TEST IMPORTS
import 'api/auto_stop_recording_test.dart' as api__auto_stop_recording_test;
import 'api/boot_preview_test.dart' as api__boot_preview_test;
import 'api/camera_view_widget_test.dart' as api__camera_view_widget_test;
import 'api/capture_events_test.dart' as api__capture_events_test;
import 'api/configure_reopen_test.dart' as api__configure_reopen_test;
import 'api/device_enumeration_test.dart' as api__device_enumeration_test;
import 'api/errors_observers_test.dart' as api__errors_observers_test;
import 'api/flash_photo_test.dart' as api__flash_photo_test;
import 'api/frame_plugin_test.dart' as api__frame_plugin_test;
import 'api/frame_stream_test.dart' as api__frame_stream_test;
import 'api/hevc_recording_test.dart' as api__hevc_recording_test;
import 'api/live_setters_test.dart' as api__live_setters_test;
import 'api/multicam_concurrent_test.dart' as api__multicam_concurrent_test;
import 'api/native_detector_test.dart' as api__native_detector_test;
import 'api/pause_resume_test.dart' as api__pause_resume_test;
import 'api/permissions_test.dart' as api__permissions_test;
import 'api/photo_burst_test.dart' as api__photo_burst_test;
import 'api/photo_variants_test.dart' as api__photo_variants_test;
import 'api/recording_controls_test.dart' as api__recording_controls_test;
import 'api/recording_errors_test.dart' as api__recording_errors_test;
import 'api/session_configure_test.dart' as api__session_configure_test;
import 'api/torch_test.dart' as api__torch_test;
import 'lifecycle/processor_scanner_test.dart' as lifecycle__processor_scanner_test;
import 'lifecycle/rapid_switch_test.dart' as lifecycle__rapid_switch_test;
import 'lifecycle/resolution_4k_test.dart' as lifecycle__resolution_4k_test;
import 'lifecycle/resolution_roundtrip_test.dart' as lifecycle__resolution_roundtrip_test;
import 'perf/back_to_back_capture_test.dart' as perf__back_to_back_capture_test;
import 'perf/device_enum_warm_test.dart' as perf__device_enum_warm_test;
import 'perf/photo_latency_test.dart' as perf__photo_latency_test;
import 'perf/setter_latency_test.dart' as perf__setter_latency_test;
import 'perf/snapshot_latency_test.dart' as perf__snapshot_latency_test;
import 'perf/store_capture_persist_test.dart' as perf__store_capture_persist_test;
import 'perf/video_latency_test.dart' as perf__video_latency_test;
// END: GENERATED TEST IMPORTS

Future<void> main() async {
  // This is the entrypoint of the bundled Dart test.
  //
  // Its responsibilities are:
  //  * Running a special Dart test that runs before all the other tests and
  //    explores the hierarchy of groups and tests.
  //  * Hosting a PatrolAppService, which the native side of Patrol uses to get
  //    the Dart tests, and to request execution of a specific Dart test.
  //
  // When running on Android, the Android Test Orchestrator, before running the
  // tests, makes an initial run to gather the tests that it will later run. The
  // native side of Patrol (specifically: PatrolJUnitRunner class) is hooked
  // into the Android Test Orchestrator lifecycle and knows when that initial
  // run happens. When it does, PatrolJUnitRunner makes an RPC call to
  // PatrolAppService and asks it for Dart tests.
  //
  // When running on iOS, the native side of Patrol (specifically: the
  // PATROL_INTEGRATION_TEST_IOS_RUNNER macro) makes an initial run to gather
  // the tests that it will later run (same as the Android). During that initial
  // run, it makes an RPC call to PatrolAppService and asks it for Dart tests.
  //
  // Once the native runner has the list of Dart tests, it dynamically creates
  // native test cases from them. On Android, this is done using the
  // Parametrized JUnit runner. On iOS, new test case methods are swizzled into
  // the RunnerUITests class, taking advantage of the very dynamic nature of
  // Objective-C runtime.
  //
  // Execution of these dynamically created native test cases is then fully
  // managed by the underlying native test framework (JUnit on Android, XCTest
  // on iOS). The native test cases do only one thing - request execution of the
  // Dart test (out of which they had been created) and wait for it to complete.
  // The result of running the Dart test is the result of the native test case.

  final platformAutomator = PlatformAutomator(
    config: PlatformAutomatorConfig.defaultConfig(),
  );
  await platformAutomator.initialize();
  final binding = PatrolBinding.ensureInitialized(platformAutomator);
  final testExplorationCompleter = Completer<DartGroupEntry>();

  // A special test to explore the hierarchy of groups and tests. This is a hack
  // around https://github.com/dart-lang/test/issues/1998.
  //
  // This test must be the first to run. If not, the native side likely won't
  // receive any tests, and everything will fall apart.
  test('patrol_test_explorer', () {
    // Maybe somewhat counterintuitively, this callback runs *after* the calls
    // to group() below.
    final topLevelGroup = Invoker.current!.liveTest.groups.first;
    final dartTestGroup = createDartTestGroup(
      topLevelGroup,
      tags: null,
      excludeTags: null,
    );
    testExplorationCompleter.complete(dartTestGroup);
    print('patrol_test_explorer: obtained Dart-side test hierarchy:');
    reportGroupStructure(dartTestGroup);
  });

// START: GENERATED TEST GROUPS
  group('api.auto_stop_recording_test', api__auto_stop_recording_test.main);
  group('api.boot_preview_test', api__boot_preview_test.main);
  group('api.camera_view_widget_test', api__camera_view_widget_test.main);
  group('api.capture_events_test', api__capture_events_test.main);
  group('api.configure_reopen_test', api__configure_reopen_test.main);
  group('api.device_enumeration_test', api__device_enumeration_test.main);
  group('api.errors_observers_test', api__errors_observers_test.main);
  group('api.flash_photo_test', api__flash_photo_test.main);
  group('api.frame_plugin_test', api__frame_plugin_test.main);
  group('api.frame_stream_test', api__frame_stream_test.main);
  group('api.hevc_recording_test', api__hevc_recording_test.main);
  group('api.live_setters_test', api__live_setters_test.main);
  group('api.multicam_concurrent_test', api__multicam_concurrent_test.main);
  group('api.native_detector_test', api__native_detector_test.main);
  group('api.pause_resume_test', api__pause_resume_test.main);
  group('api.permissions_test', api__permissions_test.main);
  group('api.photo_burst_test', api__photo_burst_test.main);
  group('api.photo_variants_test', api__photo_variants_test.main);
  group('api.recording_controls_test', api__recording_controls_test.main);
  group('api.recording_errors_test', api__recording_errors_test.main);
  group('api.session_configure_test', api__session_configure_test.main);
  group('api.torch_test', api__torch_test.main);
  group('lifecycle.processor_scanner_test', lifecycle__processor_scanner_test.main);
  group('lifecycle.rapid_switch_test', lifecycle__rapid_switch_test.main);
  group('lifecycle.resolution_4k_test', lifecycle__resolution_4k_test.main);
  group('lifecycle.resolution_roundtrip_test', lifecycle__resolution_roundtrip_test.main);
  group('perf.back_to_back_capture_test', perf__back_to_back_capture_test.main);
  group('perf.device_enum_warm_test', perf__device_enum_warm_test.main);
  group('perf.photo_latency_test', perf__photo_latency_test.main);
  group('perf.setter_latency_test', perf__setter_latency_test.main);
  group('perf.snapshot_latency_test', perf__snapshot_latency_test.main);
  group('perf.store_capture_persist_test', perf__store_capture_persist_test.main);
  group('perf.video_latency_test', perf__video_latency_test.main);
// END: GENERATED TEST GROUPS

  final dartTestGroup = await testExplorationCompleter.future;
  final appService = PatrolAppService(topLevelDartTestGroup: dartTestGroup);
  binding.patrolAppService = appService;
  await runAppService(appService);

  // Until now, the native test runner was waiting for us, the Dart side, to
  // come alive. Now that we did, let's tell it that we're ready to be asked
  // about Dart tests.
  await platformAutomator.markPatrolAppServiceReady();

  await appService.testExecutionCompleted;
}
