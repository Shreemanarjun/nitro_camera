import Flutter
import UIKit

public class SwiftNitroCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroCameraRegistry.register(NitroCameraImpl())
    }
}
