import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Boundary-parse contract of the typed device model (0.0.1): unknown wire
/// values from a NEWER native layer clamp/skip safely, and malformed payloads
/// throw typed errors instead of masquerading as "no cameras".
Map<String, dynamic> _deviceJson({
  Object? position = 1,
  Object? lensType = 1,
  Object? hardwareLevel = 'full',
  List<String> physicalDevices = const ['wide-angle-camera'],
  List<String> extensions = const [],
  List<Map<String, dynamic>>? formats,
}) => {
  'id': 'cam0',
  'name': 'Back Camera',
  'position': position,
  'lensType': lensType,
  'sensorOrientation': 90,
  'minZoom': 1.0,
  'maxZoom': 8.0,
  'neutralZoom': 1.0,
  'hasFlash': true,
  'hasTorch': true,
  'maxPhotoWidth': 4000,
  'maxPhotoHeight': 3000,
  'hardwareLevel': hardwareLevel,
  'physicalDevices': physicalDevices,
  'extensions': extensions,
  'formats':
      formats ??
      [
        {
          'photoWidth': 4000,
          'photoHeight': 3000,
          'videoWidth': 1920,
          'videoHeight': 1080,
          'minFps': 15.0,
          'maxFps': 30.0,
          'autoFocusSystem': 'phase-detection',
          'videoStabilizationModes': ['off', 'standard'],
        },
      ],
};

void main() {
  test('happy path parses to the typed model', () {
    final d = CameraDeviceInfo.fromJson(_deviceJson(extensions: ['night', 'hdr'], physicalDevices: ['wide-angle-camera', 'telephoto-camera']));
    expect(d.position, CameraPosition.back);
    expect(d.lensType, CameraLensType.wideAngle);
    expect(d.hardwareLevel, HardwareLevel.full);
    expect(d.physicalDevices, [
      PhysicalDeviceType.wideAngleCamera,
      PhysicalDeviceType.telephotoCamera,
    ]);
    expect(d.extensions, [CameraExtension.night, CameraExtension.hdr]);
    expect(d.formats.single.autoFocusSystem, AutoFocusSystem.phaseDetection);
    expect(d.formats.single.videoStabilizationModes, [VideoStabilizationMode.off, VideoStabilizationMode.standard]);
  });

  test('unknown position / lensType indices clamp instead of throwing', () {
    final d = CameraDeviceInfo.fromJson(_deviceJson(position: 99, lensType: -3));
    expect(d.position, CameraPosition.external);
    expect(d.lensType, CameraLensType.unknown);
  });

  test('unknown hardwareLevel string falls back to full', () {
    expect(CameraDeviceInfo.fromJson(_deviceJson(hardwareLevel: 'quantum')).hardwareLevel, HardwareLevel.full);
    expect(CameraDeviceInfo.fromJson(_deviceJson(hardwareLevel: 'legacy')).hardwareLevel, HardwareLevel.legacy);
  });

  test('unknown lens / extension wire strings are skipped, not errors', () {
    final d = CameraDeviceInfo.fromJson(
      _deviceJson(
        physicalDevices: ['wide-angle-camera', 'periscope-camera'],
        extensions: ['night', 'unknown-7'],
      ),
    );
    expect(d.physicalDevices, [PhysicalDeviceType.wideAngleCamera]);
    expect(d.extensions, [CameraExtension.night]);
  });

  test('unknown stabilization strings skip; empty falls back to [off]', () {
    final d = CameraDeviceInfo.fromJson(
      _deviceJson(
        formats: [
          {
            'photoWidth': 100,
            'photoHeight': 100,
            'videoWidth': 100,
            'videoHeight': 100,
            'minFps': 30.0,
            'maxFps': 30.0,
            'videoStabilizationModes': ['hyper-steady'],
          },
        ],
      ),
    );
    expect(d.formats.single.videoStabilizationModes, [VideoStabilizationMode.off]);
  });

  test('unknown autoFocusSystem falls back to none', () {
    final d = CameraDeviceInfo.fromJson(
      _deviceJson(
        formats: [
          {
            'photoWidth': 100,
            'photoHeight': 100,
            'videoWidth': 100,
            'videoHeight': 100,
            'minFps': 30.0,
            'maxFps': 30.0,
            'autoFocusSystem': 'laser',
          },
        ],
      ),
    );
    expect(d.formats.single.autoFocusSystem, AutoFocusSystem.none);
  });

  test('malformed payloads throw session/malformed-payload, never []', () {
    expect(
      () => CameraDeviceInfo.listFromJson('not json at all'),
      throwsA(isA<SessionException>().having((e) => e.code, 'code', 'session/malformed-payload')),
    );
    expect(
      () => CameraDeviceInfo.listFromJson('{"an":"object"}'),
      throwsA(isA<SessionException>()),
    );
    // A well-formed empty array IS "no cameras".
    expect(CameraDeviceInfo.listFromJson('[]'), isEmpty);
  });
}
