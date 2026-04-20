// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
    ],
    targets: [
        .target(
            name: "CameraKit",
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: ["CameraKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
