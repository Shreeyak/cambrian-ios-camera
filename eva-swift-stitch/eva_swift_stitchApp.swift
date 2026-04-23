//
//  eva_swift_stitchApp.swift
//  eva-swift-stitch
//
//  Created by shrek on 4/14/26.
//

import SwiftUI
import UIKit
import CameraKit

// Enforces landscape-right at the UIKit level regardless of device rotation.
// Info.plist UISupportedInterfaceOrientations~ipad alone is not always respected
// by SwiftUI WindowGroup on iPadOS.
private class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscapeRight
    }
}

@main
struct eva_swift_stitchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        CameraKitLog.isEnabled = true
        CameraKitLog.enableFileLogging()  // writes to <Documents>/camerakit.log
    }

    var body: some Scene {
        WindowGroup {
            CameraView()
        }
    }
}
