// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cambrian_ios_camera",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "cambrian-ios-camera", targets: ["cambrian_ios_camera"]),
    ],
    dependencies: [
        // Repo root holds the CameraKit Package.swift. From this file,
        // ../../.. resolves to:
        //   .  → flutter/ios/cambrian_ios_camera/
        //   .. → flutter/ios/
        //   ../.. → flutter/
        //   ../../.. → repo root (Package.swift lives here)
        .package(path: "../../.."),
    ],
    targets: [
        .target(
            name: "cambrian_ios_camera",
            dependencies: [
                // Root Package.swift declares `name: "CameraKit"`; path-deps
                // identify by that declared name, NOT by the repo / git-URL slug.
                .product(name: "CameraKit", package: "CameraKit"),
            ],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
    ]
)
