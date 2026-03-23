import 'package:nitro/nitro.dart';

part 'nitro_camera.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class NitroCamera extends HybridObject {
  static final NitroCamera instance = _NitroCameraImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
