import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_camera/nitro_camera.dart';

/// Test plugin: mean luma of the frame, sampled every `step` pixels.
class LumaMeanPlugin extends FrameProcessorPlugin {
  final int step;
  int frames = 0; // per-instance state lives on the worker isolate

  LumaMeanPlugin(super.options) : step = (options['step'] as int?) ?? 1;

  @override
  Object? callback(FrameData frame) {
    frames++;
    var sum = 0;
    var n = 0;
    for (var i = 0; i < frame.bytes.length; i += step) {
      sum += frame.bytes[i];
      n++;
    }
    return {'mean': sum / n, 'frames': frames};
  }
}

FrameProcessorPlugin createLumaMeanPlugin(Map<String, Object?> options) =>
    LumaMeanPlugin(options);

/// Plugin that always returns null (never emits).
class SilentPlugin extends FrameProcessorPlugin {
  SilentPlugin(super.options);
  @override
  Object? callback(FrameData frame) => null;
}

FrameProcessorPlugin createSilentPlugin(Map<String, Object?> options) =>
    SilentPlugin(options);

FrameData _grayFrame(int value) => FrameData(
      bytes: Uint8List.fromList(List.filled(64, value)),
      width: 8,
      height: 8,
      format: 0,
      timestamp: 1,
    );

void main() {
  group('FrameProcessorPlugins registry', () {
    test('init of an unknown name throws with registered names listed', () {
      expect(
        () => FrameProcessorPlugins.init('nope'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('register + isRegistered + registeredNames', () {
      FrameProcessorPlugins.register('lumaMean', createLumaMeanPlugin);
      expect(FrameProcessorPlugins.isRegistered('lumaMean'), isTrue);
      expect(FrameProcessorPlugins.registeredNames, contains('lumaMean'));
    });

    test('built-in scanCodes plugin registers', () {
      registerBuiltInFrameProcessorPlugins();
      expect(FrameProcessorPlugins.isRegistered('scanCodes'), isTrue);
    });
  });

  group('FrameProcessorPluginRunner', () {
    test('instantiates the plugin on the worker with options and runs it',
        () async {
      FrameProcessorPlugins.register('lumaMean', createLumaMeanPlugin);
      final runner = FrameProcessorPlugins.init('lumaMean', {'step': 2});
      await runner.start();
      final first = runner.results.first;
      runner.submit(_grayFrame(100));
      final result = await first as Map;
      expect(result['mean'], 100.0);
      expect(result['frames'], 1);
      await runner.dispose();
    });

    test('plugin state persists across frames (worker-isolate instance)',
        () async {
      FrameProcessorPlugins.register('lumaMean', createLumaMeanPlugin);
      final runner = FrameProcessorPlugins.init('lumaMean');
      await runner.start();
      final collected = <Map>[];
      final sub = runner.results.listen((r) => collected.add(r as Map));
      runner.submit(_grayFrame(10));
      await runner.stats.first;
      runner.submit(_grayFrame(20));
      await runner.stats.first;
      await sub.cancel();
      expect(collected.length, 2);
      expect(collected[0]['frames'], 1);
      expect(collected[1]['frames'], 2, reason: 'same instance both frames');
      await runner.dispose();
    });

    test('null returns are filtered from results but timed in stats',
        () async {
      FrameProcessorPlugins.register('silent', createSilentPlugin);
      final runner = FrameProcessorPlugins.init('silent');
      await runner.start();
      final emitted = <Object?>[];
      final sub = runner.results.listen(emitted.add);
      final stat = runner.stats.first;
      runner.submit(_grayFrame(50));
      final s = await stat;
      expect(s.success, isFalse);
      await sub.cancel();
      expect(emitted, isEmpty);
      await runner.dispose();
    });
  });
}
