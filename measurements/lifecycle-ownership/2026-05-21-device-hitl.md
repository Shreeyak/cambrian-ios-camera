# Lifecycle ownership — device HITL evidence (2026-05-21)

Device: Shreeyak's iPad Pro 11" (2nd gen, iPad8,9), iOS 26.4.2.
Build: worktree `lifecycle-analysis` @ `deb98c8` (host migrated to
`setLifecyclePhase`), deployed via `build_run_device`.
Logs: `Documents/camerakit.log` via `CameraKitLog.enableFileLogging()`, pulled
with `scripts/device-log-live.sh` (the `ipad-logs` skill). Sessions
`2026-05-21 15:34/15:37/16:05 UTC`.

## Scenarios & results

| # | Scenario | Result |
|---|---|---|
| 1 | Cold launch, foregrounded | ✅ Preview live (sub-second; exact ≤1s to re-confirm) |
| 2 | Foreground → background → foreground (short and >5 s) | ✅ Preview returns; resumes very quickly; camera LED off while backgrounded |
| 3 | Start recording → background mid-recording → foreground | ✅ `.mp4` lands in Files, **uncorrupted** (finalize-before-stop) |
| 4 | Control Center pull-down → dismiss | ✅ Preview resumes, no error dialog; ~500 ms resume (see below — expected OS latency) |
| F4 | Camera-off on background **launch** | Not separately reproduced (needs launch-into-background); structurally guaranteed by `initialPhase: .background` + reconcile-against-`.background`, the same mechanism verified in #2/#3. Defer observable check to natural occurrence. |

No off-map transitions, no spurious recovery, no crashes, no errors in any
`2026-05-21` HITL session (the only recovery/error log lines are from an earlier
`12:04` unit-test session with deliberate `error=boom`/`hw` injection).

## Control Center resume (~500 ms) — expected, not a regression

Control Center on iPad fires a genuine AVF camera interruption
(`rawReason=1` = `videoDeviceNotAvailableInBackground`); the device is OS-stopped
while CC is open. The ~500 ms is AVF's interruption-recovery latency on the OS's
timeline, not the app's — the F2 OS-owned guard correctly defers rather than
fighting the OS. Background resume is faster because the interruption ends while
backgrounded, so there is no active interruption to recover from at foreground.

```
21:30:50.928 [scenePhase] scenePhase: active → inactive          # CC down
21:30:50.941 [consumers] yield: frame=21300 ...                  # frames still flowing
21:30:52.023 [engine] [interruption] ended=false rawReason=1     # AVF interrupts (camera unavailable)
21:30:52.025 [engine] [interruption] entering .interrupted
21:30:52.202 [scenePhase] scenePhase: inactive → active          # CC dismissed
21:30:52.203 [engine] [lifecycle] skipping command label from=interrupted to=streaming
             caller=reconcile() (deferring to OS-owned state)    # F2 guard fires — don't fight the OS
21:30:52.255 [engine] [interruption] ended=true rawReason=-1
21:30:52.257 [engine] [interruption] ended — reconciling against currentPhase   # Task 8 OS→phase
21:30:52.683 [consumers] [metrics] window emit ...               # frames resume (~480 ms after .active)
```

## Background-during-use (representative)

```
21:31:20.367 scenePhase: active → inactive
21:31:21.656 scenePhase: inactive → background
21:31:21.927 [interruption] ended=false rawReason=1              # OS interrupts on background
21:31:21.928 [interruption] entering .interrupted
21:31:21.928 [interruption] ended=true                           # ends immediately while backgrounded
21:31:21.928 [interruption] ended — reconciling against currentPhase   # currentPhase=.background → stays stopped
21:31:29.800 scenePhase: background → inactive                   # resume: session restarts at .inactive
21:31:30.006 scenePhase: inactive → active                       # gate opens at .active
```

Rapid scenePhase bounces (e.g. `21:33:20–28`, repeated `active↔inactive`)
produced no off-map / recovery — latest-intent-wins (F1) holds on device.

## On-device confirmations of the new model

- New reconcile path is live (no legacy `[bgsuspend]`/`[bgresume]` logs; the host
  forwards via `setLifecyclePhase` — `scenePhase: prev → next`).
- F2 `osOwnsDevice` deferral fires during the CC interruption (log above).
- Task 8 OS→phase reconcile runs on every `interruption ended`.
- Recording across a background produced a playable `.mp4` (user-confirmed).
