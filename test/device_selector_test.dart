import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

CameraDeviceInfo _device(
  String id, {
  CameraPosition position = CameraPosition.back,
  HardwareLevel hardwareLevel = HardwareLevel.full,
  List<PhysicalDeviceType> physicalDevices = const [PhysicalDeviceType.wideAngleCamera],
}) => CameraDeviceInfo(
  id: id,
  name: id,
  position: position,
  lensType: CameraLensType.wideAngle,
  sensorOrientation: 90,
  minZoom: 1,
  maxZoom: 8,
  neutralZoom: 1,
  hasFlash: true,
  hasTorch: true,
  maxPhotoWidth: 4000,
  maxPhotoHeight: 3000,
  hardwareLevel: hardwareLevel,
  physicalDevices: physicalDevices,
);

void main() {
  group('selectCameraDevice', () {
    test('filters by position', () {
      final devices = [
        _device('front', position: CameraPosition.front),
        _device('back'),
      ];
      expect(
        selectCameraDevice(devices, position: CameraPosition.back)?.id,
        'back',
      );
      expect(
        selectCameraDevice(devices, position: CameraPosition.front)?.id,
        'front',
      );
      expect(
        selectCameraDevice(devices, position: CameraPosition.external),
        isNull,
      );
    });

    test('prefers full hardware level', () {
      final devices = [
        _device('legacy', hardwareLevel: HardwareLevel.legacy),
        _device('full'),
      ];
      expect(selectCameraDevice(devices)?.id, 'full');
    });

    test('prefers wide-angle by default', () {
      final devices = [
        _device('tele', physicalDevices: [PhysicalDeviceType.telephotoCamera]),
        _device('wide'),
      ];
      expect(selectCameraDevice(devices)?.id, 'wide');
    });

    test('explicit non-wide request drops the wide-angle bonus', () {
      final devices = [
        _device('wide'),
        _device('tele', physicalDevices: [PhysicalDeviceType.telephotoCamera]),
      ];
      final picked = selectCameraDevice(
        devices,
        physicalDevices: [PhysicalDeviceType.telephotoCamera],
      );
      expect(picked?.id, 'tele');
    });

    test('exact lens match beats a logical camera with extra lenses', () {
      final devices = [
        _device(
          'triple',
          physicalDevices: [
            PhysicalDeviceType.ultraWideAngleCamera,
            PhysicalDeviceType.wideAngleCamera,
            PhysicalDeviceType.telephotoCamera,
          ],
        ),
        _device('ultrawide', physicalDevices: [PhysicalDeviceType.ultraWideAngleCamera]),
      ];
      final picked = selectCameraDevice(
        devices,
        physicalDevices: [PhysicalDeviceType.ultraWideAngleCamera],
      );
      // triple: -1 (wide unrequested... wide not requested → -1) etc.
      expect(picked?.id, 'ultrawide');
    });

    test('logical camera wins when ALL its lenses are requested', () {
      final devices = [
        _device('wide'),
        _device(
          'triple',
          physicalDevices: [
            PhysicalDeviceType.ultraWideAngleCamera,
            PhysicalDeviceType.wideAngleCamera,
            PhysicalDeviceType.telephotoCamera,
          ],
        ),
      ];
      final picked = selectCameraDevice(
        devices,
        physicalDevices: PhysicalDeviceType.values,
      );
      expect(picked?.id, 'triple');
    });

    test('ties keep the first device (enumeration order)', () {
      final devices = [_device('a'), _device('b')];
      expect(selectCameraDevice(devices)?.id, 'a');
    });

    test('extension sugar: backCamera / frontCamera', () {
      final devices = [
        _device('front', position: CameraPosition.front),
        _device('back'),
      ];
      expect(devices.backCamera()?.id, 'back');
      expect(devices.frontCamera()?.id, 'front');
      expect(devices.externalCamera(), isNull);
    });
  });
}
