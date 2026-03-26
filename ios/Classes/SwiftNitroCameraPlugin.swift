import Flutter
import UIKit

public class SwiftNitroCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        nitro_camera_exampleRegistry.register(nitro_camera_exampleModuleImpl())
        let impl = NitroCameraImpl(textureRegistry: registrar.textures())
        NitroCameraRegistry.register(impl)
    }
}
