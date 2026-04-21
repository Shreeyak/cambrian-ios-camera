# Stage 04 HITL evidence

Device: iPad (physical device, platform=iOS)
Date: 2026-04-21
Build: eva-swift-stitch (Debug configuration)

## 04:color-slider-visual-correctness — DEFERRED

DEFERRED — device smoke test requires physical device interaction; automated
session cannot observe visual output. App builds and deploys successfully.
Build verified via mcp__XcodeBuildMCP__build_device. Device locked at time of
execution; manual unlock and verification required: tap "Calibrate Color"; move
sliders; confirm right-half preview changes while left half (natural) stays
unchanged; Reset returns to identity.

## 04:rapid-slider-stress-sees-occasional-torn-frame — DEFERRED

DEFERRED — rapid slider drag for ~10s must be performed manually. The
`04:unlocked-uniforms` scaffold acknowledges torn writes are perceptually
benign at slider speed; Stage 05 locks will retire this scaffold.

## ProcessingParameters persistence (LLDB)

DEFERRED — `po UserDefaults.standard.data(forKey: "CameraKit.ProcessingParameters")`
must be run while app is live after moving sliders. Full evidence pending manual
session on physical iPad with device unlocked.

## Metal System Trace (Instruments) — DEFERRED

Pass 1 + Pass 2 wall-clock per frame, peak frame latency, GPU utilisation to be
captured via Instruments Metal System Trace. Expected: < 33 ms per frame
(Constants.frameLatencyBudgetMs). Deferred pending Instruments availability.
