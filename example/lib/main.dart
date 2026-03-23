import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_camera/nitro_camera.dart' as plugin;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NitroCamera Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const _DemoPage(),
    );
  }
}

class _DemoPage extends StatefulWidget {
  const _DemoPage();
  @override
  State<_DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<_DemoPage> {
  String _addResult = '—';
  double? _addResultTimeMs;
  final List<double> _addTimes = [];
  Future<String>? _greetingFuture;
  double? _greetingTimeMs;
  final List<double> _greetingTimes = [];
  Timer? _timer;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _init();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _init());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _init() async {
    try {
      // 1. measure sync call
      final sw1 = Stopwatch()..start();
      final r1 = plugin.NitroCamera.instance.add(1.0, 2.0);
      sw1.stop();

      // 2. start async call
      final sw2 = Stopwatch()..start();
      final future = plugin.NitroCamera.instance.getGreeting('World');
      
      final currentSyncTime = sw1.elapsedMicroseconds / 1000.0;
      _addTimes.add(currentSyncTime);

      setState(() {
        _addResult = '$r1';
        _addResultTimeMs = currentSyncTime;
        _greetingFuture = future;
        _greetingTimeMs = null; // reset for new run
      });

      // 3. wait for async result and measure
      await future;
      sw2.stop();

      if (mounted) {
        final currentAsyncTime = sw2.elapsedMicroseconds / 1000.0;
        _greetingTimes.add(currentAsyncTime);
        setState(() {
          _greetingTimeMs = currentAsyncTime;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _initError = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('NitroCamera Demo')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                const Text('Failed to load native library',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_initError!,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('NitroCamera Demo'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _init,
            icon: const Icon(Icons.refresh),
            tooltip: 'Run Benchmark',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.bolt, size: 36, color: Colors.amber),
              const SizedBox(width: 8),
              Text(
                'NitroCamera',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Nitro FFI module — edit lib/src/nitro_camera.native.dart to add methods.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _FeatureCard(
            label: 'Sync method',
            code: 'NitroCamera.instance.add(1.0, 2.0)',
            result: _addResult,
            timeMs: _addResultTimeMs,
            avgTimeMs: _addTimes.isEmpty
                ? null
                : _addTimes.reduce((a, b) => a + b) / _addTimes.length,
            callCount: _addTimes.length,
          ),
          const SizedBox(height: 12),
          FutureBuilder<String>(
            future: _greetingFuture,
            builder: (context, snapshot) => _FeatureCard(
              label: 'Async method  (@nitroAsync)',
              code: 'await NitroCamera.instance.getGreeting("World")',
              result: snapshot.hasData
                  ? snapshot.data!
                  : snapshot.hasError
                      ? 'Error: ${snapshot.error}'
                      : null,
              timeMs: _greetingTimeMs,
              avgTimeMs: _greetingTimes.isEmpty
                  ? null
                  : _greetingTimes.reduce((a, b) => a + b) /
                      _greetingTimes.length,
              callCount: _greetingTimes.length,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.label,
    required this.code,
    required this.result,
    this.timeMs,
    this.avgTimeMs,
    this.callCount = 0,
  });
  final String label;
  final String code;
  final String? result; // null = loading
  final double? timeMs;
  final double? avgTimeMs;
  final int callCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(code,
                      style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                          fontFamily: 'monospace')),
                  if (timeMs != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${timeMs!.toStringAsFixed(3)}ms',
                        style: const TextStyle(
                            color: Colors.deepPurple,
                            fontWeight: FontWeight.bold,
                            fontSize: 10),
                      ),
                    ),
                  ],
                  if (avgTimeMs != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color: Colors.deepPurple.withOpacity(0.1)),
                      ),
                      child: Text(
                        'Avg: ${avgTimeMs!.toStringAsFixed(3)}ms',
                        style: TextStyle(
                            color: Colors.deepPurple.withOpacity(0.7),
                            fontWeight: FontWeight.bold,
                            fontSize: 10),
                      ),
                    ),
                  ],
                  if (callCount > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Count: $callCount',
                      style: TextStyle(
                          color: Colors.grey.withOpacity(0.8),
                          fontSize: 10,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            result == null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    result!,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple),
                  ),
          ],
        ),
      ),
    );
  }
}
