import 'package:flutter/material.dart';
import 'dart:async';

import 'package:nitro_camera/nitro_camera.dart' as nitro_camera;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late double sumResult;
  late Future<String> sumAsyncResult;

  @override
  void initState() {
    super.initState();
    sumResult = nitro_camera.NitroCamera.instance.add(1.0, 2.0);
    sumAsyncResult = nitro_camera.NitroCamera.instance.getGreeting("HelloDev");
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 25);
    const spacerSmall = SizedBox(height: 10);
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Native Packages')),
        body: SingleChildScrollView(
          child: Container(
            padding: const .all(10),
            child: Column(
              children: [
                const Text(
                  'This calls a native function through FFI that is shipped as source in the package. '
                  'The native code is built as part of the Flutter Runner build.',
                  style: textStyle,
                  textAlign: .center,
                ),
                spacerSmall,
                Text(
                  'sum(1, 2) = $sumResult',
                  style: textStyle,
                  textAlign: .center,
                ),
                spacerSmall,
                FutureBuilder<String>(
                  future: sumAsyncResult,
                  builder: (BuildContext context, AsyncSnapshot<String> value) {
                    final displayValue = (value.hasData)
                        ? value.data
                        : 'loading';
                    return Text(
                      'await sumAsync(3, 4) = $displayValue',
                      style: textStyle,
                      textAlign: .center,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
