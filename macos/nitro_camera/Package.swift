// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "nitro_camera",
  platforms: [.macOS(.v10_15)],
  products: [
    .library(name: "nitro-camera", targets: ["nitro_camera"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "NitroCameraCpp",
      path: "Sources/NitroCameraCpp",
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include"),
        .unsafeFlags(["-std=c++17"])
      ]
    ),
    .target(
      name: "nitro_camera",
      dependencies: [
        "NitroCameraCpp",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      path: "Sources/NitroCamera"
    )
  ]
)
