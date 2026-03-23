// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nitro_camera",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "nitro_camera", targets: ["nitro_camera"]),
    ],
    targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        .target(
            name: "NitroCameraCpp",
            path: "Sources/NitroCameraCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-std=c++17",
                    // nitro's dart_api_dl.h — resolved via Flutter's symlink
                    // so this works for both local path and pub.dev references.
                    "-I../../.symlinks/plugins/nitro/src/native",
                ])
            ]
        ),
        // Swift implementation + generated bridge.
        .target(
            name: "nitro_camera",
            dependencies: ["NitroCameraCpp"],
            path: "Sources/NitroCamera"
        ),
    ]
)
