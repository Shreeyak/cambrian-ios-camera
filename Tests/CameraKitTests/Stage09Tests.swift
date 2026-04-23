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
