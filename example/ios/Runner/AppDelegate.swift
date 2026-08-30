import CoreVideo
import Flutter
import UIKit
import nitro_camera

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Demo of the native frame-processor plugin registry: a dependency-free
    // custom detector registered by the host app, selectable from Dart via
    // controller.setNativeDetector("meanLuma"). Mirrors the Android
    // MainActivity registration. Registration is idempotent (overwrites).
    NitraDetectors.register("meanLuma") { MeanLumaEngine() }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// Computes the average scene luminance (0..255). Reads the luma plane for a
/// planar YUV buffer, or the green channel as a proxy for BGRA.
struct MeanLumaEngine: DetectorEngine {
  func detect(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [[String: Any]]? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    var sum = 0
    var n = 0
    if CVPixelBufferIsPlanar(pixelBuffer),
       let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
      let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
      let pw = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
      let ph = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
      let p = base.assumingMemoryBound(to: UInt8.self)
      var y = 0
      while y < ph {
        let row = y * rowBytes
        var x = 0
        while x < pw { sum += Int(p[row + x]); n += 1; x += 16 }
        y += 4
      }
    } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
      let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
      let p = base.assumingMemoryBound(to: UInt8.self)
      var y = 0
      while y < height {
        let row = y * rowBytes
        var x = 0
        while x < width { sum += Int(p[row + x * 4 + 1]); n += 1; x += 16 }
        y += 4
      }
    }
    let mean = n > 0 ? sum / n : 0
    return [["luma": mean]]
  }
}
