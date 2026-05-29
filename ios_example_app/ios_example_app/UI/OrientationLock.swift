import UIKit

/// Single read path for the declared orientation policy.
///
/// Stage 06 enforces `landscape-right-only` via `Info.plist`
/// (`UISupportedInterfaceOrientations~ipad`) plus the `UIApplicationDelegateAdaptor`.
/// Tests and HITL evidence read the policy through this enum so the source of truth
/// is one place.
public enum OrientationLock {

    public static var declaredSupported: UIInterfaceOrientationMask { .landscapeRight }
}
