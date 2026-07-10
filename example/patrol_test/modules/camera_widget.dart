import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';
import 'package:nitro_camera/native.dart' show NitroCamera;

import 'module.dart';

/// Library-level test of the declarative `CameraView` widget — mounted RAW
/// (no example-app store): permission via the native dialog, then the
/// widget's own contract: publish a controller, toggle isActive without a
/// reopen, and double-buffered device switch with onClosing/onInitialized.
final class CameraWidget extends Module {
  CameraWidget(super.$);

  Future<void> verifyDeclarativeLifecycle() async {
    // Permission WITHOUT the app's UI flow: request + guarded native grant.
    // requestCameraPermission() asks for CAMERA **and** RECORD_AUDIO in one
    // native call and its result fires only after BOTH dialogs are answered —
    // so accept BOTH (acceptPermissionDialogs loops), or `req` hangs forever.
    if (NitroCamera.instance.getCameraPermissionStatus() !=
        PermissionStatus.granted.index) {
      final req = CameraController.requestCameraPermission();
      await acceptPermissionDialogs();
      expect(await req, PermissionStatus.granted);
    }

    final devices = await CameraController.getAvailableCameraDevices();
    expect(devices, isNotEmpty);
    final back = devices.backCamera() ?? devices.first;

    CameraController? current;
    ResolvedCameraConfig? resolved;
    final events = <CameraSessionEvent>[];
    var closings = 0;

    Widget build(CameraDeviceInfo device, {required bool active}) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: CameraView(
          device: device,
          isActive: active,
          previewMode: PreviewMode.texture,
          onInitialized: (c) => current = c,
          onClosing: () => closings++,
          onConfigResolved: (r) => resolved = r,
          onEvent: events.add,
        ),
      );
    }

    await $.tester.pumpWidget(build(back, active: true));
    await pumpUntil(
      () => current?.isInitialized ?? false,
      reason: 'CameraView published an initialized controller',
    );
    final firstTid = current!.textureId;
    expect(firstTid, isNotNull);
    expect(firstTid, isNot(0));
    expect(resolved, isNotNull,
        reason: 'onConfigResolved reports the negotiated config');

    // isActive toggle: streaming stops/starts, NO reopen (same textureId).
    await $.tester.pumpWidget(build(back, active: false));
    await pumpFor(const Duration(seconds: 1));
    expect(current!.isActive, isFalse);
    expect(current!.textureId, firstTid);

    await $.tester.pumpWidget(build(back, active: true));
    await pumpUntil(() => current!.isActive,
        reason: 'preview resumed after isActive=true');
    expect(current!.textureId, firstTid);

    // Device switch: double-buffered swap → onClosing fires, a NEW controller
    // with a NEW textureId is published, and the session streams again.
    final front = devices.frontCamera();
    if (front != null && front.id != back.id) {
      await $.tester.pumpWidget(build(front, active: true));
      await pumpUntil(
        () =>
            (current?.isInitialized ?? false) &&
            current!.textureId != firstTid,
        timeout: const Duration(seconds: 20),
        reason: 'double-buffered swap published the new session',
      );
      expect(closings, greaterThan(0),
          reason: 'onClosing must fire before the old session is torn down');
      expect(current!.device.id, front.id);
      await pumpUntil(() => current!.getSessionState().running,
          reason: 'new device streaming after the swap');
    }

    // Teardown: unmount → the widget disposes its controller.
    await $.tester.pumpWidget(
        const MaterialApp(home: SizedBox.shrink()));
    await pumpFor(const Duration(milliseconds: 800));
    expect(events.every((e) => !e.isError), isTrue,
        reason: 'no error events during the declarative lifecycle '
            '(${events.where((e) => e.isError).map((e) => e.message)})');
  }
}
