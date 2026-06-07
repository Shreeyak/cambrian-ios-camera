// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CameraKit",
    // macOS is declared only so the platform-neutral `FrameTransport` product
    // builds for a macOS host (its sole downstream is EvaScan's Mac + iOS app).
    // CameraKit itself remains iOS-only — it imports AVFoundation and never
    // builds on a macOS host (CLAUDE.md §6); a whole-package `swift build` on
    // macOS still fails there, by design. Use `swift build --target FrameTransport`.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
        // Platform-neutral shared frame vocabulary (Frame / PixelHandle /
        // FrameMetadata / Lane / PixelFormat / BufferingPolicy). iOS + macOS;
        // CoreVideo/Foundation only, no AVFoundation. Importable standalone.
        .library(name: "FrameTransport", targets: ["FrameTransport"]),
        // TEMPORARY (Phase 1A): exported so the relocated DisplayViewModel
        // can `import CameraKitInterop` for CppCannyStub. Phase 1B removes
        // the OpenCV/Canny consumer from the package and unexports this.
        .library(name: "CameraKitInterop", targets: ["CameraKitInterop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // Platform-neutral shared frame vocabulary. No dependencies, no
        // AVFoundation — CoreVideo/Foundation only — so it builds on a macOS
        // host as well as iOS, and is importable without the rest of CameraKit.
        .target(
            name: "FrameTransport",
            path: "CameraKit/Sources/FrameTransport",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // C++ PixelSink pool + atomics. No OpenCV — Phase 1B (2026-05-15) moved
        // the Canny consumer + the opencv2 xcframework into the ios_example_app
        // app target. The package contains the consumer-join seam only.
        .target(
            name: "CameraKitCxx",
            path: "CameraKit/Sources/CameraKitCxx",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("CPP_POOL_THREAD_COUNT", to: "4"),
                .headerSearchPath("include"),
            ]
        ),
        // Thin Swift C++ interop boundary — .interoperabilityMode(.Cxx) confined here (ADR-13).
        .target(
            name: "CameraKitInterop",
            dependencies: ["CameraKitCxx"],
            path: "CameraKit/Sources/CameraKitInterop",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "CameraKit",
            dependencies: [
                "CameraKitInterop",
                "FrameTransport",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "CameraKit/Sources/CameraKit",
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Required to import CameraKitInterop (built with C++ interop).
                // No C++ types appear in CameraKit's public API — containment per ADR-13 is met.
                .interoperabilityMode(.Cxx),
            ]
        ),
        // Informational stub. Produces a clear `#error` for anyone who runs
        // `swift test` reflexively. The real test suite lives in
        // CameraKit/Tests/CameraKitTests/ and is compiled by the Xcode
        // ios_example_appTests target (app-hosted on iPad).
        .testTarget(
            name: "SPMTestStub",
            path: "CameraKit/Tests/SPMTestStub"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
