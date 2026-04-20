// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "CameraKit",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: [
                "CameraKit",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
