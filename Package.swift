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
        // CameraKit is pure Swift since frame-delivery-rework removed the C-ABI
        // PixelSink path (the former CameraKitCxx + CameraKitInterop targets and
        // the .interoperabilityMode(.Cxx) boundary are gone).
        .target(
            name: "CameraKit",
            dependencies: [
                "FrameTransport",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "CameraKit/Sources/CameraKit",
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6)
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
    ]
)
