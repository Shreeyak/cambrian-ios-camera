import Testing
import Atomics
@testable import CameraKit

@Suite("Stage 09 — watchdog identity")
struct Stage09WatchdogTests {
    @Test("armed token is captured at arm and stable across refresh")
    func tokenCapturedAtArm() async {
        let clock = SystemClock()
        let wd = Watchdog(kind: .gpu, clock: clock) { _ in
            Issue.record("callback must not fire in this test")
        }
        wd.arm(sessionToken: 42)
        wd.refresh()
        #expect(wd.armedSessionToken == 42)
        wd.disarm()
        #expect(wd.armedSessionToken == nil)
    }
}

@Suite("Stage 09 — recovery backoff")
struct Stage09RecoveryTests {
    @Test("backoff schedule matches constants (1..5+)")
    func backoffMatchesConstants() async {
        #expect(Constants.recoveryBackoffMs(attempt: 1) == 500)
        #expect(Constants.recoveryBackoffMs(attempt: 2) == 1000)
        #expect(Constants.recoveryBackoffMs(attempt: 3) == 2000)
        #expect(Constants.recoveryBackoffMs(attempt: 4) == 4000)
        #expect(Constants.recoveryBackoffMs(attempt: 5) == 8000)
        #expect(Constants.recoveryBackoffMs(attempt: 9) == 8000)
    }
}
