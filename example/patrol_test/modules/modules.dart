import 'package:patrol/patrol.dart';

import 'camera.dart';
import 'camera_apis.dart';
import 'camera_widget.dart';
import 'performance.dart';
import 'preview.dart';
import 'store.dart';

export 'camera.dart';
export 'camera_apis.dart';
export 'camera_widget.dart';
export 'performance.dart';
export 'preview.dart';
export 'store.dart';

/// Aggregates the feature modules handed to every test by `testApp`.
final class Modules {
  Modules(this._$);

  final PatrolIntegrationTester _$;

  late final camera = Camera(_$);
  late final cameraApis = CameraApis(_$);
  late final cameraWidget = CameraWidget(_$);
  late final performance = Performance(_$);
  late final preview = Preview(_$);
  late final store = Store(_$);
}
