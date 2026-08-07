import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';

CameraDeviceInfo dev({String id = 'back', int sensorOrientation = 90}) => CameraDeviceInfo(
  id: id,
  name: 'Camera $id',
  position: CameraPosition.back,
  lensType: CameraLensType.wideAngle,
  sensorOrientation: sensorOrientation,
  minZoom: 1.0,
  maxZoom: 8.0,
  neutralZoom: 1.0,
  hasFlash: true,
  hasTorch: true,
  maxPhotoWidth: 4032,
  maxPhotoHeight: 3024,
);

CameraDeviceFormat fmt({int w = 1920, int h = 1080}) => CameraDeviceFormat(
  photoWidth: w,
  photoHeight: h,
  videoWidth: w,
  videoHeight: h,
  minFps: 30,
  maxFps: 30,
);

/// [FakeNitroCamera] whose `openCamera` can be suspended, so the widget's
/// "still opening" states are observable instead of racing to completion
/// inside a single microtask drain.
class GatedFake extends FakeNitroCamera {
  /// Set to hold the NEXT `openCamera` until completed.
  Completer<void>? openGate;

  @override
  Future<int> openCamera(String deviceId, int width, int height, int fps, int enableAudio) async {
    final gate = openGate;
    if (gate != null) {
      openGate = null;
      await gate.future;
    }
    return super.openCamera(deviceId, width, height, fps, enableAudio);
  }
}

extension on FakeNitroCamera {
  int countOf(String name) => calls.where((c) => c.name == name).length;
  int indexOf(String name) => callNames.indexOf(name);
}

void main() {
  late GatedFake fake;

  setUp(() => fake = GatedFake());
  tearDown(() => fake.close());

  Widget wrap(Widget child) => MaterialApp(home: child);

  group('CameraView initial open', () {
    testWidgets('shows loading first, then the preview once openCamera resolves', (tester) async {
      final gate = Completer<void>();
      fake.openGate = gate;
      final initialised = <CameraController>[];
      ResolvedCameraConfig? resolved;

      await tester.pumpWidget(
        wrap(
          CameraView(
            device: dev(),
            format: fmt(),
            native: fake,
            onInitialized: initialised.add,
            onConfigResolved: (r) => resolved = r,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(CameraPreview), findsNothing);
      expect(initialised, isEmpty);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CameraPreview), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(initialised, hasLength(1));
      expect(initialised.single.textureId, 7);
      expect(resolved, isNotNull);
      expect(resolved!.videoWidth, 1920);
      expect(fake.argsOf('openCamera'), ['back', 1920, 1080, 30, 0]);
    });

    testWidgets('a custom loading widget replaces the default spinner', (tester) async {
      final gate = Completer<void>();
      fake.openGate = gate;

      await tester.pumpWidget(
        wrap(CameraView(device: dev(), native: fake, loading: const Text('warming up'))),
      );

      expect(find.text('warming up'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('warming up'), findsNothing);
      expect(find.byType(CameraPreview), findsOneWidget);
    });

    testWidgets('opening with isActive false immediately stops the preview', (tester) async {
      await tester.pumpWidget(wrap(CameraView(device: dev(), native: fake, isActive: false)));
      await tester.pumpAndSettle();

      expect(fake.argsOf('stopPreview'), [7]);
      expect(fake.called('startPreview'), isFalse);
      expect(find.byType(CameraPreview), findsOneWidget);
    });

    testWidgets('audio and explicit dimensions reach openCamera', (tester) async {
      await tester.pumpWidget(
        wrap(CameraView(device: dev(), native: fake, width: 1280, height: 720, fps: 60, audio: true)),
      );
      await tester.pumpAndSettle();

      expect(fake.argsOf('openCamera'), ['back', 1280, 720, 60, 1]);
    });

    testWidgets('the child overlay renders on top of the preview', (tester) async {
      await tester.pumpWidget(
        wrap(CameraView(device: dev(), native: fake, child: const Text('hud'))),
      );
      await tester.pumpAndSettle();

      final stack = tester.widget<Stack>(
        find.descendant(of: find.byKey(const ValueKey('nitra_camera_live')), matching: find.byType(Stack)).first,
      );
      expect(stack.children.last, isA<Text>());
      expect(find.text('hud'), findsOneWidget);
    });
  });

  group('CameraView open failure', () {
    testWidgets('retries with exponential backoff, gives up after 5 attempts', (tester) async {
      fake.openCameraResult = 0;
      final errors = <Object>[];

      await tester.pumpWidget(
        wrap(
          CameraView(
            device: dev(),
            native: fake,
            onError: errors.add,
            errorBuilder: (e, retry) => const Text('camera unavailable'),
          ),
        ),
      );

      expect(fake.countOf('openCamera'), 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(errors, isEmpty);

      await tester.pump(const Duration(milliseconds: 249));
      expect(fake.countOf('openCamera'), 1, reason: 'still inside the 250ms backoff');
      await tester.pump(const Duration(milliseconds: 1));
      expect(fake.countOf('openCamera'), 2);

      await tester.pump(const Duration(milliseconds: 499));
      expect(fake.countOf('openCamera'), 2, reason: 'backoff doubled to 500ms');
      await tester.pump(const Duration(milliseconds: 1));
      expect(fake.countOf('openCamera'), 3);

      await tester.pump(const Duration(seconds: 1));
      expect(fake.countOf('openCamera'), 4);
      await tester.pump(const Duration(seconds: 2));
      expect(fake.countOf('openCamera'), 5);

      await tester.pump(const Duration(seconds: 10));
      expect(fake.countOf('openCamera'), 5, reason: 'bounded at _maxOpenAttempts');
      expect(find.text('camera unavailable'), findsOneWidget);
      expect(errors, hasLength(1));
      expect(errors.single, isA<DeviceException>());
      expect((errors.single as DeviceException).code, 'device/open-failed');
    });

    testWidgets('without an errorBuilder the loading state stays and onError still fires', (tester) async {
      fake.openCameraResult = 0;
      final errors = <Object>[];

      await tester.pumpWidget(wrap(CameraView(device: dev(), native: fake, onError: errors.add)));
      for (final d in [250, 500, 1000, 2000]) {
        await tester.pump(Duration(milliseconds: d));
      }
      await tester.pump();

      expect(errors, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(CameraPreview), findsNothing);
    });

    testWidgets('the errorBuilder retry re-opens and recovers', (tester) async {
      fake.openCameraResult = 0;
      VoidCallback? retry;
      final errors = <Object>[];

      await tester.pumpWidget(
        wrap(
          CameraView(
            device: dev(),
            native: fake,
            onError: errors.add,
            errorBuilder: (e, r) {
              retry = r;
              return const Text('camera unavailable');
            },
          ),
        ),
      );
      for (final d in [250, 500, 1000, 2000]) {
        await tester.pump(Duration(milliseconds: d));
      }
      await tester.pump();
      expect(find.text('camera unavailable'), findsOneWidget);

      fake.openCameraResult = 7;
      retry!();
      await tester.pump();
      expect(find.text('camera unavailable'), findsNothing, reason: 'the error state is cleared up front');

      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(fake.countOf('openCamera'), 6);
      expect(errors, hasLength(1), reason: 'the successful retry reports no new error');
    });
  });

  group('CameraView didUpdateWidget', () {
    Widget view({
      String id = 'back',
      int? width,
      int fps = 30,
      bool audio = false,
      bool isActive = true,
      Duration settleDelay = Duration.zero,
      void Function(CameraController)? onInitialized,
      VoidCallback? onClosing,
    }) => wrap(
      CameraView(
        device: dev(id: id),
        width: width,
        height: width == null ? null : 720,
        fps: fps,
        audio: audio,
        isActive: isActive,
        settleDelay: settleDelay,
        native: fake,
        onInitialized: onInitialized,
        onClosing: onClosing,
      ),
    );

    testWidgets('a device switch double-buffers: the retiring preview outlives the new open', (tester) async {
      final opened = <CameraController>[];
      var closings = 0;
      const settle = Duration(milliseconds: 40);

      await tester.pumpWidget(
        view(settleDelay: settle, onInitialized: opened.add, onClosing: () => closings++),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nitra_preview_7')), findsOneWidget);
      expect(closings, 0);

      fake.openCameraResult = 9;
      await tester.pumpWidget(
        view(id: 'front', settleDelay: settle, onInitialized: opened.add, onClosing: () => closings++),
      );
      await tester.pump();

      expect(closings, 1);
      expect(opened, hasLength(2));
      expect(find.byKey(const ValueKey('nitra_preview_9')), findsOneWidget);
      expect(find.byKey(const ValueKey('nitra_retiring_7')), findsOneWidget);
      expect(find.byType(CameraPreview), findsNWidgets(2));
      expect(opened.first.textureId, 7, reason: 'the retiring controller is still alive');
      expect(
        fake.indexOf('closeCamera') < fake.callNames.lastIndexOf('openCamera'),
        isTrue,
        reason: 'the old camera hardware is released before the new one opens',
      );

      await tester.pump(settle);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('nitra_retiring_7')), findsNothing);
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(opened.first.textureId, isNull, reason: 'the retiring controller is disposed after the swap');
      expect(fake.countOf('closeCamera'), 1, reason: 'closeSession already closed it');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a device switch that reuses the texture id renders a single preview', (tester) async {
      await tester.pumpWidget(view(settleDelay: const Duration(milliseconds: 40)));
      await tester.pumpAndSettle();

      await tester.pumpWidget(view(id: 'front', settleDelay: const Duration(milliseconds: 40)));
      await tester.pump();

      expect(find.byType(CameraPreview), findsOneWidget);
      expect(find.byKey(const ValueKey('nitra_preview_7')), findsOneWidget);
      expect(find.byKey(const ValueKey('nitra_retiring_7')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsOneWidget);
    });

    testWidgets('a resolution change tears down first, waits out settleDelay, then reopens', (tester) async {
      var closings = 0;
      const settle = Duration(milliseconds: 30);

      await tester.pumpWidget(view(width: 1280, settleDelay: settle, onClosing: () => closings++));
      await tester.pumpAndSettle();
      expect(fake.argsOf('openCamera'), ['back', 1280, 720, 30, 0]);
      fake.clear();

      await tester.pumpWidget(view(width: 1920, settleDelay: settle, onClosing: () => closings++));
      await tester.pump();

      expect(closings, 1);
      expect(fake.callNames, ['closeCamera'], reason: 'the session is gone before the reopen');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('nitra_retiring_7')), findsNothing);

      await tester.pump(settle);
      await tester.pumpAndSettle();

      expect(fake.argsOf('openCamera'), ['back', 1920, 720, 30, 0]);
      expect(find.byType(CameraPreview), findsOneWidget);
    });

    testWidgets('an fps change reopens the session', (tester) async {
      await tester.pumpWidget(view(fps: 30));
      await tester.pumpAndSettle();
      fake.clear();

      await tester.pumpWidget(view(fps: 60));
      await tester.pumpAndSettle();

      expect(fake.argsOf('openCamera'), ['back', 1920, 1080, 60, 0]);
      expect(fake.countOf('closeCamera'), 1);
    });

    testWidgets('an audio change reopens the session', (tester) async {
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      fake.clear();

      await tester.pumpWidget(view(audio: true));
      await tester.pumpAndSettle();

      expect(fake.argsOf('openCamera'), ['back', 1920, 1080, 30, 1]);
    });

    testWidgets('toggling isActive only starts/stops the preview, never reopens', (tester) async {
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      fake.clear();

      await tester.pumpWidget(view(isActive: false));
      await tester.pump();
      expect(fake.callNames, ['stopPreview']);
      expect(fake.argsOf('stopPreview'), [7]);

      await tester.pumpWidget(view(isActive: true));
      await tester.pump();
      expect(fake.callNames, ['stopPreview', 'startPreview']);

      expect(fake.called('openCamera'), isFalse);
      expect(fake.called('closeCamera'), isFalse);
      expect(find.byType(CameraPreview), findsOneWidget);
    });

    testWidgets('an unrelated rebuild touches nothing', (tester) async {
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      fake.clear();

      await tester.pumpWidget(view());
      await tester.pumpAndSettle();

      expect(fake.calls, isEmpty);
    });
  });

  group('CameraView session events', () {
    testWidgets('a native error event keeps the preview mounted and reports through onError', (tester) async {
      final events = <CameraSessionEvent>[];
      final errors = <Object>[];

      await tester.pumpWidget(
        wrap(
          CameraView(
            device: dev(),
            native: fake,
            onEvent: events.add,
            onError: errors.add,
            errorBuilder: (e, retry) => const Text('error-ui'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      fake.emitEvent(CameraEventType.error.index, textureId: 7, message: 'HAL hiccup');
      await tester.pump();

      expect(events, hasLength(1));
      expect(events.single.type, CameraEventType.error);
      expect(errors, hasLength(1));
      expect(errors.single, isA<SessionException>());
      expect((errors.single as SessionException).code, 'session/native-error');
      expect((errors.single as SessionException).message, 'HAL hiccup');
      expect(find.byType(CameraPreview), findsOneWidget, reason: 'a live session survives an error event');
      expect(find.text('error-ui'), findsNothing);
    });

    testWidgets('a non-error event reaches onEvent only', (tester) async {
      final events = <CameraSessionEvent>[];
      final errors = <Object>[];

      await tester.pumpWidget(
        wrap(CameraView(device: dev(), native: fake, onEvent: events.add, onError: errors.add)),
      );
      await tester.pumpAndSettle();

      fake.emitEvent(CameraEventType.started.index, textureId: 7);
      await tester.pump();

      expect(events, hasLength(1));
      expect(events.single.type, CameraEventType.started);
      expect(errors, isEmpty);
      expect(find.byType(CameraPreview), findsOneWidget);
    });

    testWidgets('the event subscription follows the reopened session', (tester) async {
      final events = <CameraSessionEvent>[];
      Widget view(int width) => wrap(
        CameraView(device: dev(), width: width, height: 720, native: fake, onEvent: events.add),
      );

      await tester.pumpWidget(view(1280));
      await tester.pumpAndSettle();

      fake.openCameraResult = 9;
      await tester.pumpWidget(view(1920));
      await tester.pumpAndSettle();

      fake.emitEvent(CameraEventType.started.index, textureId: 7);
      await tester.pump();
      expect(events, isEmpty, reason: 'events for the dead session are filtered out');

      fake.emitEvent(CameraEventType.started.index, textureId: 9);
      await tester.pump();
      expect(events, hasLength(1));
    });
  });

  group('CameraView teardown', () {
    testWidgets('unmounting mid-open disposes the controller and never setStates', (tester) async {
      final gate = Completer<void>();
      fake.openGate = gate;
      var closings = 0;

      await tester.pumpWidget(
        wrap(CameraView(device: dev(), native: fake, onClosing: () => closings++)),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(wrap(const SizedBox()));
      gate.complete();
      await tester.pumpAndSettle();

      expect(fake.argsOf('closeCamera'), [7], reason: 'the orphaned session is closed');
      expect(closings, 0, reason: 'no controller was ever published');
      expect(tester.takeException(), isNull);
    });

    testWidgets('unmounting a live view closes the session and notifies onClosing', (tester) async {
      var closings = 0;

      await tester.pumpWidget(
        wrap(CameraView(device: dev(), native: fake, onClosing: () => closings++)),
      );
      await tester.pumpAndSettle();
      expect(fake.called('closeCamera'), isFalse);

      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.pumpAndSettle();

      expect(closings, 1);
      expect(fake.argsOf('closeCamera'), [7]);
    });

    testWidgets('a restart queued behind an unmount aborts instead of reopening', (tester) async {
      const settle = Duration(milliseconds: 60);
      var closings = 0;
      Widget view(String id) => wrap(
        CameraView(device: dev(id: id), native: fake, settleDelay: settle, onClosing: () => closings++),
      );

      await tester.pumpWidget(view('a'));
      await tester.pumpAndSettle();

      // Swap to 'b'. The double-buffered restart parks on settleDelay with the
      // new controller already published, so the queue is busy.
      fake.openCameraResult = 9;
      await tester.pumpWidget(view('b'));
      await tester.pump();
      expect(find.byKey(const ValueKey('nitra_retiring_7')), findsOneWidget);

      // Queue a second switch behind it, then unmount before either finishes.
      await tester.pumpWidget(view('c'));
      await tester.pumpWidget(wrap(const SizedBox()));

      await tester.pump(settle);
      await tester.pumpAndSettle();

      expect(fake.countOf('openCamera'), 2, reason: 'the queued restart must not open a third session');
      expect(closings, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    });
  });
}
