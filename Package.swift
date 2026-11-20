// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DroidMirror",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DroidMirrorCore", targets: ["DroidMirrorCore"]),
        .executable(name: "droidmirror", targets: ["droidmirror"]),
        .executable(name: "DroidMirrorApp", targets: ["DroidMirrorApp"]),
    ],
    targets: [
        .target(name: "DroidMirrorCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "droidmirror", dependencies: ["DroidMirrorCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "DroidMirrorApp",
            dependencies: ["DroidMirrorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DroidMirrorCoreTests", dependencies: ["DroidMirrorCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
