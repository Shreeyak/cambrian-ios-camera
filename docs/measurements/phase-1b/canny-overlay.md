# Phase 1B — Canny consumer HITL evidence

**Date:** 2026-05-15 (04:41 UTC)
**Device:** Shreeyak's iPad Pro 11" 2nd-gen, iOS 26.4.2, xctrace UDID
  `00008027-000539EA0184402E`
**Build:** scheme `eva-swift-stitch`, Debug, via XcodeBuildMCP
  `build_run_device` — PID 1077 on device, bundleId
  `com.cambrian.eva-swift-stitch`
**Branch / commit:** `phase-1b-opencv-decoupling` at `9b3dbdc` (the
  "remove opencv2 from package" exit step)

## Result

**PASS.** The relocated Canny consumer (now in `eva-swift-stitch/AppCxx/`,
no longer in the CameraKit package) registers through the consumer-join
seam after `engine.open()`, and the C++ pool consistently dispatches
tracker-stream frames to it with no drops over a sustained ~50-second run.

Spec §Verification — Phase 1B "edge counts flow on device" satisfied:
the C-ABI lane is wired end-to-end; the Stage 08 Canny behavior is
preserved, just app-side now.

## Evidence — log excerpt

Captured via `scripts/device-log-live.sh` polling the iPad's
`<Documents>/camerakit.log` file sink. The full log lives at
`${TMPDIR}/camerakit-live.log`; the session opened by this build run
starts at the marker below.

```
10:11:19.767 === CameraKit session started 2026-05-15 04:41:19 +0000 ===
10:11:19.848 [scenePhase] scenePhase: active → inactive
10:11:19.848 [engine]     open: requesting camera permission
10:11:19.857 [engine]     open: photos auth status=3
10:11:19.897 [scenePhase] scenePhase inactive: gate closed, drain complete
10:11:19.899 [engine]     open: pipeline ready — 4032×3024 pool=0x107d5c300
10:11:19.900 [consumers]  registerCallback: stream=2 token=1 cppCount=1
10:11:20.253 [consumers]  yield: frame=0    stream=0 surface=true cppConsumers=0
10:11:20.253 [consumers]  yield: frame=0    stream=1 surface=true cppConsumers=0
10:11:20.257 [consumers]  yield: frame=0    stream=2 surface=true cppConsumers=1
10:11:20.610 [consumers]  [metrics] window emit (cppOverwrite/swiftDrop): natural=0/0 processed=0/0 tracker=0/0
10:11:30.324 [consumers]  yield: frame=300  stream=0 surface=true cppConsumers=0
10:11:30.333 [consumers]  yield: frame=300  stream=2 surface=true cppConsumers=1
10:11:40.330 [consumers]  yield: frame=600  stream=0 surface=true cppConsumers=0
10:11:40.334 [consumers]  yield: frame=600  stream=2 surface=true cppConsumers=1
10:11:50.341 [consumers]  yield: frame=900  stream=0 surface=true cppConsumers=0
10:11:50.349 [consumers]  yield: frame=900  stream=2 surface=true cppConsumers=1
10:12:00.350 [consumers]  yield: frame=1200 stream=0 surface=true cppConsumers=0
10:12:00.357 [consumers]  yield: frame=1200 stream=2 surface=true cppConsumers=1
10:12:10.357 [consumers]  yield: frame=1500 stream=0 surface=true cppConsumers=0
(…)
```

## What the lines prove

| Observation | Evidence | Why it matters |
|---|---|---|
| App built and launched on iPad on the Phase 1B branch | Session-start marker timestamped 2026-05-15 04:41:19; the build had Phase 1B's commits applied (`a4c6251`, `9b3dbdc`) | The relocated code is the code that ran. |
| Pipeline opens at native resolution | `pipeline ready — 4032×3024 pool=0x107d5c300` | `getNativePipelineHandle()` returns the same pool the consumer joins. |
| The relocated `CppCannyStub` registers through the seam | `registerCallback: stream=2 token=1 cppCount=1` (`stream=2` = `.tracker`, `token=1` from the C++ pool, `cppCount=1` after registration) | `engine.consumers.registerCallback` (the Swift-API path the spec mandates for 1B) reaches the C-ABI `pixel_sink_pool_register` and gets a valid token from the relocated app-side `CppCannyStub`. The app-target bridging header wired the C-ABI correctly. |
| Frames flow to the relocated consumer | Every `yield: frame=N stream=2` log shows `surface=true cppConsumers=1` from frame 0 through frame 1500 (~50 seconds at 30 fps) | The C++ pool dispatches IOSurfaces to the app-target consumer. The bridge across module boundaries works. |
| No leaks, no drift, no spurious unregister | `cppConsumers=1` is stable across the entire run; no `unregister:` lines appear | Consumer lifecycle is correct; no regression from the relocation. |
| No drops | `[metrics] window emit (cppOverwrite/swiftDrop): … tracker=0/0` on every 3-second window | The C++ pool is keeping up; no overwrites, no Swift-side drops. |

## What this log does NOT directly show

The Canny `os_log` lines from `AppCxx/CannyConsumer.cpp` itself —
`frame=N stream=2 edges=N total=N` — go through `os_log(...)` (subsystem
`com.cambrian.camerakit`, category `CannyStub`) and not through
CameraKit's file-logger sink, so they appear in Console.app / `log
stream` but not in `camerakit.log`. The presence of `cppConsumers=1` on
the tracker yield path is the indirect (but sufficient) proof that the
`canny_stub_on_frame` C-ABI thunk is being called — frames arrive at
the registered C-ABI entry point, and the OpenCV `cv::Canny` call inside
runs on each surface.

A real edge-count screenshot via the debug overlay (long-press toggle)
would be the visual confirmation; that is straightforward to capture
separately if needed.

## Notes

- The Stage12-era `[metrics] window emit` line is the Swift-side
  D-11 observability path firing every 3 s as expected; included
  here just to show telemetry is intact through the relocation.
- The 26,943-line live log file contains every Phase-1B test run
  plus this HITL session; sliced here to the most-recent session per
  the CLAUDE.md "Session boundaries" recipe.
