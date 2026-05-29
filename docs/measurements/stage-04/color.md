# Stage 04 HITL evidence

Device: Shreeyak's iPad (iOS 26.4.1, device ID 00008027-000539EA0184402E)
Date: 2026-04-21
Build: eva-swift-stitch (Debug configuration)

## 04:color-slider-visual-correctness — PASS

Split preview renders correctly: left half shows natural camera, right half
shows processed output. "Calibrate Color" sidebar opens/closes. Brightness,
Saturation, Contrast, Gamma, Black R/G/B sliders all update the right-half
preview live while the left half (natural) stays unchanged. Reset returns
both halves to identity (visually matching). Verified on Shreeyak's iPad
(iOS 26.4.1), 2026-04-21.

## 04:rapid-slider-stress-sees-occasional-torn-frame — PASS

Rapid slider drag for ~10s: 0 visible single-frame glitches observed.
The `04:unlocked-uniforms` scaffold (torn writes perceptually benign at
slider speed) did not produce any observable artifacts in this session.
Stage 05 `OSAllocatedUnfairLock<UniformStorage>` will retire this scaffold.

## ProcessingParameters persistence — PASS

Sliders set to non-default values (Brightness +0.3, Gamma 1.5); app
force-quit and relaunched — slider positions restored from UserDefaults
key `"CameraKit.ProcessingParameters"`. Verified on Shreeyak's iPad
(iOS 26.4.1), 2026-04-21.

## Metal System Trace (Instruments) — DEFERRED

Pass 1 + Pass 2 wall-clock per frame, peak frame latency, GPU utilisation to be
captured via Instruments Metal System Trace. Expected: < 33 ms per frame
(Constants.frameLatencyBudgetMs). Deferred pending Instruments availability.
