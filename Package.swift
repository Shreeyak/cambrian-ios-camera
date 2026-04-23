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
        // OpenCV v4.13 xcframework for Canny edge detection (ADR-29).
        // Path is relative to CameraKit/Package.swift.
        // Only ios-arm64 slice present; sufficient for physical iPad + Mac "Designed for iPad".
        .binaryTarget(
            name: "opencv2",
            path: "../Frameworks/opencv2.xcframework"
        ),
        // C++ PixelSink pool + Canny stub consumer.
        // OpenCV confined here; no OpenCV symbols escape to public headers (ADR-11).
        .target(
            name: "CameraKitCxx",
            dependencies: ["opencv2"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("CPP_POOL_THREAD_COUNT", to: "4"),
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
        // Thin Swift C++ interop boundary — .interoperabilityMode(.Cxx) confined here (ADR-13).
        .target(
            name: "CameraKitInterop",
            dependencies: ["CameraKitCxx"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "CameraKit",
            dependencies: [
                "CameraKitInterop",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Required to import CameraKitInterop (built with C++ interop).
                // No C++ types appear in CameraKit's public API — containment per ADR-13 is met.
                .interoperabilityMode(.Cxx),
            ]
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: [
                "CameraKit",
                "CameraKitInterop",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
