//
//  ios_example_appApp.swift
//  ios_example_app
//
//  Created by shrek on 4/14/26.
//

import CameraKit
import SwiftUI
import UIKit

// Enforces landscape-right at the UIKit level regardless of device rotation.
// Info.plist UISupportedInterfaceOrientations~ipad alone is not always respected
// by SwiftUI WindowGroup on iPadOS.
private class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.declaredSupported
    }
}

@main
struct ios_example_appApp: App {
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
