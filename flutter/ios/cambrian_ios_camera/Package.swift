// swift-tools-version: 6.2
import Foundation
import PackageDescription

// CameraKit's Package.swift lives at the repo root. A literal
// `.package(path: "../../..")` does NOT work here: Flutter's SPM integration
// symlinks this package into
// `<example>/ios/Flutter/ephemeral/Packages/.packages/cambrian_ios_camera`,
// and SPM resolves relative dependency paths from the *symlink* location, so
// `../../..` lands on the ephemeral dir (named "ephemeral") rather than the
// repo root, and CameraKit can't be found.
//
// Resolve `#filePath` through symlinks to recover the real manifest location,
// then walk up four levels (cambrian_ios_camera → ios → flutter → repo root).
// This is correct both standalone and under Flutter's symlink.
let repoRoot = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()  // .../flutter/ios/cambrian_ios_camera/
    .deletingLastPathComponent()  // .../flutter/ios/
    .deletingLastPathComponent()  // .../flutter/
    .deletingLastPathComponent()  // repo root (CameraKit Package.swift lives here)
    .path

let package = Package(
    name: "cambrian_ios_camera",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "cambrian-ios-camera", targets: ["cambrian_ios_camera"]),
    ],
    dependencies: [
        // Root Package.swift declares `name: "CameraKit"`; the explicit `name:`
        // pins the dependency identity so `.product(package: "CameraKit")`
        // resolves regardless of the repo/worktree directory basename.
        .package(name: "CameraKit", path: repoRoot),
    ],
    targets: [
        .target(
            name: "cambrian_ios_camera",
            dependencies: [
                .product(name: "CameraKit", package: "CameraKit"),
            ],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: [
                // Swift 5 language mode: the Pigeon-generated code (and Flutter's
                // own globals like `FlutterEndOfEventStream`) are not written for
                // Swift 6 strict concurrency, so forcing `.v6` turns Pigeon's
                // generated globals into hard errors. The hand-written adapter is
                // concurrency-aware regardless (actors, Sendable captures).
                .swiftLanguageMode(.v5),
                // CameraKit/CameraKitInterop are built with C++ interop (ADR-13);
                // importing them requires the importer to enable it too, even
                // though no C++ types cross CameraKit's public API. The Xcode
                // RunnerTests target sets the equivalent
                // `-cxx-interoperability-mode=default` for its `@testable import`.
                .interoperabilityMode(.Cxx),
            ]
        ),
    ]
)
