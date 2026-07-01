import FlutterMacOS
import Foundation

public class NitroCameraPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    NitroCameraRegistry.register(NitroCameraModuleImpl())
    // Nitro registration will be injected here by nitrogen link.
  }
}
