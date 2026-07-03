/// Frame-processor **plugin system** — the Dart analogue of vision-camera's
/// `FrameProcessorPluginRegistry` + `VisionCameraProxy.initFrameProcessorPlugin`.
///
/// A plugin is a named, reusable per-frame processor. Registration binds a
/// name to a factory; initialization spawns a persistent worker isolate that
/// instantiates the plugin there (so per-plugin state lives off the UI
/// isolate) and runs it on every streamed frame with drop-latest backpressure.
///
/// ```dart
/// // 1. Register once (e.g. in main()). The factory MUST be a top-level or
/// //    static function — it is sent to the worker isolate.
/// FrameProcessorPlugins.register('lumaMean', createLumaMeanPlugin);
///
/// // 2. Initialize + attach to the camera:
/// final runner = FrameProcessorPlugins.init('lumaMean', {'step': 16});
/// await runner.start(NitroCamera.instance.frameStream);
/// runner.results.listen((mean) => print('luma: $mean'));
/// ```
library;

import 'dart:async';

import '../nitro_camera.native.dart' show CameraFrame;
import 'frame_processor.dart';

/// A per-frame processor instantiated ON THE WORKER ISOLATE with the options
/// passed to [FrameProcessorPlugins.init]. Mirrors vision-camera's
/// `FrameProcessorPlugin` (Android `FrameProcessorPlugin(options)` /
/// `callback(frame, params)`).
abstract class FrameProcessorPlugin {
  /// The options this instance was initialized with (never null; may be empty).
  final Map<String, Object?> options;
  const FrameProcessorPlugin(this.options);

  /// Processes one frame. Runs on the worker isolate. The returned value is
  /// emitted on [FrameProcessorPluginRunner.results] and must be
  /// isolate-sendable (primitives, lists/maps of sendables, ...). Return null
  /// for "nothing detected on this frame".
  ///
  /// Teardown note: disposing the runner KILLS the worker isolate, which
  /// reclaims all plugin memory — there is no per-plugin dispose callback.
  Object? callback(FrameData frame);
}

/// Creates a [FrameProcessorPlugin] from init [options]. **Must be a top-level
/// or static function** — it crosses the isolate boundary.
typedef FrameProcessorPluginFactory = FrameProcessorPlugin Function(
    Map<String, Object?> options);

// ── Worker-isolate side ──────────────────────────────────────────────────────

/// The plugin instance living on THIS worker isolate (one runner = one worker
/// = one plugin instance).
FrameProcessorPlugin? _workerPlugin;

void _pluginWorkerInit(Object? arg) {
  final msg = arg as List<Object?>;
  final factory = msg[0] as FrameProcessorPluginFactory;
  final options = Map<String, Object?>.from(msg[1] as Map);
  _workerPlugin = factory(options);
}

Object? _pluginFrameHandler(FrameData frame) => _workerPlugin?.callback(frame);

// ── Main-isolate registry ────────────────────────────────────────────────────

/// Global name → factory registry (main isolate). The static API mirrors
/// vision-camera's `FrameProcessorPluginRegistry.addFrameProcessorPlugin` /
/// `initFrameProcessorPlugin`.
abstract final class FrameProcessorPlugins {
  static final Map<String, FrameProcessorPluginFactory> _registry = {};

  /// Binds [name] to [factory]. [factory] must be a top-level or static
  /// function. Registering the same name twice replaces the previous binding
  /// (hot-restart friendly).
  static void register(String name, FrameProcessorPluginFactory factory) {
    _registry[name] = factory;
  }

  /// The names of all registered plugins.
  static List<String> get registeredNames => _registry.keys.toList()..sort();

  /// Whether a plugin named [name] is registered.
  static bool isRegistered(String name) => _registry.containsKey(name);

  /// Creates a runner for the plugin registered as [name], instantiated with
  /// [options] on its own worker isolate. Throws [ArgumentError] for an
  /// unknown name (like vision-camera's "plugin not found" error).
  static FrameProcessorPluginRunner init(
    String name, [
    Map<String, Object?> options = const {},
  ]) {
    final factory = _registry[name];
    if (factory == null) {
      throw ArgumentError.value(
        name,
        'name',
        'No frame-processor plugin registered with this name. '
            'Registered: ${registeredNames.join(', ')}',
      );
    }
    return FrameProcessorPluginRunner._(name, factory, options);
  }
}

/// A running (or startable) instance of a named plugin: a persistent worker
/// isolate executing the plugin on every frame, with drop-latest backpressure
/// and zero-copy frame hand-off (see [CameraFrameProcessor]).
class FrameProcessorPluginRunner {
  /// The registered plugin name this runner executes.
  final String name;

  final CameraFrameProcessor<Object?> _proc;
  StreamSubscription<CameraFrame>? _sub;
  bool _started = false;

  FrameProcessorPluginRunner._(
    this.name,
    FrameProcessorPluginFactory factory,
    Map<String, Object?> options,
  ) : _proc = CameraFrameProcessor<Object?>(
          _pluginFrameHandler,
          workerInit: _pluginWorkerInit,
          workerInitArg: [factory, options],
        );

  /// Every non-null value the plugin returned, in completion order.
  Stream<Object?> get results => _proc.results.where((r) => r != null);

  /// Per-frame plugin timing (hit and miss) — for benchmarking HUDs.
  Stream<FrameProcessStats> get stats => _proc.stats;

  /// Spawns the worker (instantiating the plugin there) and starts consuming
  /// [frames]. Pass `null` to start without a camera and feed frames manually
  /// via [submit] (e.g. tests or still images).
  Future<void> start([Stream<CameraFrame>? frames]) async {
    if (_started) return;
    _started = true;
    await _proc.start();
    if (frames != null) _sub = _proc.attach(frames);
  }

  /// Submits one frame manually (worker must be [start]ed).
  void submit(FrameData frame) => _proc.submit(frame);

  Future<void> dispose() async {
    await _sub?.cancel();
    await _proc.dispose();
  }
}
