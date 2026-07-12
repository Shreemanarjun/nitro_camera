/// Built-in `scanCodes` frame-processor plugin — the barcode scanner exposed
/// through the generic plugin system (vision-camera ships code scanning the
/// same way). Prefer [CodeScanner] for the full typed API (confirmation,
/// one-shot, detections stream); use the plugin form when routing through
/// plugin-based pipelines.
library;

import '../processing/frame_processor.dart';
import '../processing/frame_processor_plugin.dart';
import 'code_scanner.dart';

/// Scans frames for codes of the kind named by `options['kind']`
/// (a [CodeScanKind] name, default `'all'`). Emits a map per hit:
/// `{text, format, isGs1, points}`.
class ScanCodesPlugin extends FrameProcessorPlugin {
  final CodeScanKind kind;

  ScanCodesPlugin(super.options)
    : kind = CodeScanKind.values.firstWhere(
        (k) => k.name == (options['kind'] ?? 'all'),
        orElse: () => CodeScanKind.all,
      );

  @override
  Object? callback(FrameData frame) {
    final r = scanFrameAdaptive(frame, kind);
    if (r == null) return null;
    return <String, Object?>{
      'text': r.text,
      'format': r.format.name,
      'isGs1': r.isGs1,
      'points': r.windowPoints,
    };
  }
}

/// Factory for [ScanCodesPlugin] (top-level, isolate-sendable).
FrameProcessorPlugin createScanCodesPlugin(Map<String, Object?> options) => ScanCodesPlugin(options);

/// Registers all plugins shipped with nitro_camera (currently `scanCodes`).
/// Call once, e.g. from `main()`.
void registerBuiltInFrameProcessorPlugins() {
  FrameProcessorPlugins.register('scanCodes', createScanCodesPlugin);
}
