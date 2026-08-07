import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

import '../support/fake_nitro_camera.dart';

CameraDeviceInfo dev({
  String id = 'back',
  int sensorOrientation = 90,
  double minZoom = 1.0,
  double maxZoom = 8.0,
}) => CameraDeviceInfo(
  id: id,
  name: 'Back Camera',
  position: CameraPosition.back,
  lensType: CameraLensType.wideAngle,
  sensorOrientation: sensorOrientation,
  minZoom: minZoom,
  maxZoom: maxZoom,
  neutralZoom: 1.0,
  hasFlash: true,
  hasTorch: true,
  maxPhotoWidth: 4032,
  maxPhotoHeight: 3024,
);

/// [testWidgets] pinned to a target platform.
///
/// The override has to be cleared inside the test body: `flutter_test` asserts
/// every foundation debug variable is unset the moment the body returns, before
/// any `tearDown` runs.
void testOn(TargetPlatform platform, String description, WidgetTesterCallback body) {
  testWidgets('$description [${platform.name}]', (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// Hosts [child] at an exact logical size with the [MediaQuery] the preview's
/// orientation branch reads.
Widget host(Widget child, {Size size = const Size(400, 800)}) => MediaQuery(
  data: MediaQueryData(size: size),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(size: size, child: child),
    ),
  ),
);

/// A hit-testable filler so gesture wrappers (which default to
/// `HitTestBehavior.deferToChild`) actually receive pointers.
const Widget surface = ColoredBox(color: Color(0xFF101010), child: SizedBox.expand());

/// The [SizedBox] the preview sizes to the (orientation-corrected) stream.
SizedBox streamBox(WidgetTester tester) => tester.widget<SizedBox>(
  find.descendant(of: find.byType(FittedBox), matching: find.byType(SizedBox)),
);

void main() {
  late FakeNitroCamera fake;

  setUp(() => fake = FakeNitroCamera());
  tearDown(() => fake.close());

  /// A controller with a live session (1920x1080, from the fake's session state).
  Future<CameraController> opened({int sensorOrientation = 90, int textureId = 7, double maxZoom = 8.0}) async {
    fake.openCameraResult = textureId;
    final c = CameraController(
      device: dev(sensorOrientation: sensorOrientation, maxZoom: maxZoom),
      native: fake,
    );
    await c.initialize();
    return c;
  }

  group('CameraPreview rendering modes', () {
    testWidgets('an uninitialised controller renders the spinner, not a texture', (tester) async {
      final c = CameraController(device: dev(), native: fake);
      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.texture)));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
      expect(find.byType(FittedBox), findsNothing);
    });

    testOn(TargetPlatform.iOS, 'rebuilds into the texture as soon as the controller initialises', (tester) async {
      final c = CameraController(device: dev(), native: fake);
      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.texture)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await c.initialize();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 7);
    });

    testOn(TargetPlatform.iOS, 'texture mode renders a Texture bound to the session id', (tester) async {
      final c = await opened(textureId: 42);
      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.texture)));

      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
      expect(find.byType(AndroidView), findsNothing);
    });

    testOn(TargetPlatform.iOS, 'impeller mode takes the texture path', (tester) async {
      final c = await opened();
      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.impeller)));

      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(AndroidView), findsNothing);
    });

    testOn(TargetPlatform.android, 'platformView mode builds an AndroidView keyed on the session id', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
        if (call.method == 'create') return 0;
        if (call.method == 'resize') return <Object?, Object?>{'width': 400.0, 'height': 800.0};
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null),
      );

      final c = await opened(textureId: 11);
      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.platformView)));
      await tester.pump();

      final view = tester.widget<AndroidView>(find.byType(AndroidView));
      expect(view.key, const ValueKey('nitra_pv_11'));
      expect(view.viewType, 'dev.shreeman.nitro_camera/platform_view');
      expect(view.creationParams, {'textureId': 11});
      expect(find.byType(FittedBox), findsNothing, reason: 'the native view frames itself');
    });

    testOn(TargetPlatform.iOS, 'platformView mode falls back to a Texture off Android', (tester) async {
      final c = await opened(textureId: 11);
      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.platformView)));

      expect(find.byType(AndroidView), findsNothing);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 11);
    });

    testOn(TargetPlatform.iOS, 'the child overlay renders on top of the preview', (tester) async {
      final c = await opened();
      await tester.pumpWidget(
        host(CameraPreview(controller: c, mode: PreviewMode.texture, child: const Text('hud'))),
      );

      final stack = tester.widget<Stack>(find.byType(Stack));
      expect(stack.children.length, 2);
      expect(stack.children.last, isA<Text>());
      expect(find.text('hud'), findsOneWidget);
    });

    testOn(TargetPlatform.iOS, 'no child leaves the stack with just the preview', (tester) async {
      final c = await opened();
      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.texture)));

      expect(tester.widget<Stack>(find.byType(Stack)).children.length, 1);
    });
  });

  group('CameraPreview resize mode', () {
    testOn(TargetPlatform.iOS, 'cover crops, contain letterboxes', (tester) async {
      final c = await opened();

      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.texture)));
      expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);

      await tester.pumpWidget(
        host(CameraPreview(controller: c, mode: PreviewMode.texture, resizeMode: PreviewResizeMode.contain)),
      );
      expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.contain);
    });

    testOn(TargetPlatform.android, 'cover crops with a hard clip, contain letterboxes', (tester) async {
      final c = await opened();

      await tester.pumpWidget(host(CameraPreview(controller: c, mode: PreviewMode.texture)));
      final cover = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(cover.fit, BoxFit.cover);
      expect(cover.clipBehavior, Clip.hardEdge);

      await tester.pumpWidget(
        host(CameraPreview(controller: c, mode: PreviewMode.texture, resizeMode: PreviewResizeMode.contain)),
      );
      expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.contain);
    });
  });

  group('CameraPreview orientation sizing', () {
    testOn(TargetPlatform.android, 'portrait display + rotated sensor swaps the stream dimensions', (tester) async {
      final c = await opened(sensorOrientation: 90);

      await tester.pumpWidget(
        host(CameraPreview(controller: c, mode: PreviewMode.texture), size: const Size(400, 800)),
      );

      expect(c.width, 1920);
      expect(c.height, 1080);
      expect(streamBox(tester).width, 1080.0);
      expect(streamBox(tester).height, 1920.0);
    });

    testOn(TargetPlatform.android, 'landscape display + rotated sensor keeps the stream dimensions', (tester) async {
      final c = await opened(sensorOrientation: 270);

      await tester.pumpWidget(
        host(CameraPreview(controller: c, mode: PreviewMode.texture), size: const Size(800, 400)),
      );

      expect(streamBox(tester).width, 1920.0);
      expect(streamBox(tester).height, 1080.0);
    });

    testOn(TargetPlatform.android, 'portrait display + upright sensor keeps the stream dimensions', (tester) async {
      final c = await opened(sensorOrientation: 0);

      await tester.pumpWidget(
        host(CameraPreview(controller: c, mode: PreviewMode.texture), size: const Size(400, 800)),
      );

      expect(streamBox(tester).width, 1920.0);
      expect(streamBox(tester).height, 1080.0);
    });

    testOn(TargetPlatform.android, 'the display orientation comes from the real view metrics', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);

      final c = await opened(sensorOrientation: 90);
      await tester.pumpWidget(MaterialApp(home: CameraPreview(controller: c, mode: PreviewMode.texture)));
      expect(streamBox(tester).width, 1080.0, reason: 'portrait view -> content portrait');

      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpWidget(MaterialApp(home: CameraPreview(controller: c, mode: PreviewMode.texture)));
      expect(streamBox(tester).width, 1920.0, reason: 'landscape view -> content landscape');
    });

    testOn(TargetPlatform.iOS, 'swaps on a 90 sensor and not on a 180 sensor, ignoring the display', (tester) async {
      final portraitSensor = await opened(sensorOrientation: 90);
      await tester.pumpWidget(
        host(CameraPreview(controller: portraitSensor, mode: PreviewMode.texture), size: const Size(800, 400)),
      );
      expect(streamBox(tester).width, 1080.0);
      expect(streamBox(tester).height, 1920.0);

      final uprightSensor = await opened(sensorOrientation: 180);
      await tester.pumpWidget(
        host(CameraPreview(controller: uprightSensor, mode: PreviewMode.texture), size: const Size(400, 800)),
      );
      expect(streamBox(tester).width, 1920.0);
      expect(streamBox(tester).height, 1080.0);
    });
  });

  group('TapToFocusDetector', () {
    // The 400x600 host matches the default test surface, so logical tap
    // coordinates land exactly where they are aimed.
    const gestureSize = Size(400, 600);

    testWidgets('a tap reaches the controller as normalised coordinates', (tester) async {
      final c = await opened();
      await tester.pumpWidget(
        host(TapToFocusDetector(controller: c, child: const SizedBox.expand()), size: gestureSize),
      );
      fake.clear();

      await tester.tapAt(const Offset(100, 150));

      expect(fake.argsOf('setFocusPoint'), [7, 0.25, 0.25]);
    });

    testWidgets('a tap in the far corner clamps into 0..1', (tester) async {
      final c = await opened();
      await tester.pumpWidget(
        host(TapToFocusDetector(controller: c, child: const SizedBox.expand()), size: gestureSize),
      );
      fake.clear();

      await tester.tapAt(const Offset(399.9, 599.9));

      final args = fake.argsOf('setFocusPoint')!;
      expect(args[1] as double, inInclusiveRange(0.99, 1.0));
      expect(args[2] as double, inInclusiveRange(0.99, 1.0));
    });
  });

  group('PinchToZoomDetector', () {
    Future<void> pinch(WidgetTester tester, {required double spread}) async {
      const centre = Offset(200, 400);
      final a = await tester.startGesture(centre - const Offset(50, 0));
      final b = await tester.startGesture(centre + const Offset(50, 0));
      await tester.pump();
      await a.moveTo(centre - Offset(50 * spread, 0));
      await b.moveTo(centre + Offset(50 * spread, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pump();
    }

    testWidgets('spreading the fingers zooms in proportionally', (tester) async {
      final c = await opened();
      await tester.pumpWidget(host(PinchToZoomDetector(controller: c, child: surface)));
      fake.clear();

      await pinch(tester, spread: 2.0);

      expect(fake.called('setZoom'), isTrue);
      final zoom = fake.argsOf('setZoom')![1] as double;
      expect(zoom, closeTo(2.0, 0.001));
      expect(c.zoom, zoom);
    });

    testWidgets('zoom is clamped to the maxZoom override', (tester) async {
      final c = await opened();
      await tester.pumpWidget(host(PinchToZoomDetector(controller: c, maxZoom: 1.5, child: surface)));
      fake.clear();

      await pinch(tester, spread: 4.0);

      expect(fake.argsOf('setZoom')![1], 1.5);
    });

    testWidgets('zoom is clamped to the minZoom override when pinching in', (tester) async {
      final c = await opened();
      await tester.pumpWidget(host(PinchToZoomDetector(controller: c, minZoom: 1.2, child: surface)));
      fake.clear();

      await pinch(tester, spread: 0.2);

      expect(fake.argsOf('setZoom')![1], 1.2);
    });

    testWidgets('the second pinch starts from the zoom the first one left behind', (tester) async {
      final c = await opened();
      await tester.pumpWidget(host(PinchToZoomDetector(controller: c, child: surface)));

      await pinch(tester, spread: 2.0);
      expect(c.zoom, closeTo(2.0, 0.001));

      await pinch(tester, spread: 2.0);
      expect(c.zoom, closeTo(4.0, 0.01), reason: 'baseZoom is re-read on scale start');
    });

    testWidgets('without overrides the zoom clamps to the device range', (tester) async {
      final c = await opened(maxZoom: 3.0);
      await tester.pumpWidget(host(PinchToZoomDetector(controller: c, child: surface)));
      fake.clear();

      await pinch(tester, spread: 8.0);

      expect(fake.argsOf('setZoom')![1], 3.0);
    });
  });
}
