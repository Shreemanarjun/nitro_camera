import Flutter
import UIKit

public class SwiftNitroCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let impl = NitroCameraImpl(textureRegistry: registrar.textures())
        NitroCameraRegistry.register(impl)
    }
}
