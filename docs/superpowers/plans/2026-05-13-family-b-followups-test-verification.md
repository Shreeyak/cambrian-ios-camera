# Family B Follow-ups — Test Verification (post host-app wiring)

This plan exists because the Family B reviewer-follow-up changes landed
without runtime verification: as of 2026-05-13, tests cannot execute on
this machine (see
`docs/superpowers/plans/2026-05-13-camerakit-tests-host-app-wiring.md`).
The code changes compile clean and were reviewed manually; tests for the
new semantics were written eagerly and committed alongside the changes,
but they have only been **build-verified**, not **run**. The source
punch-list (`2026-05-08-family-b-followups.md`) was closed and deleted;
the resolution narrative survives in `CameraKit/state.md` and the
Family B commit body.

**Build verification confirmed (2026-05-13).** Full clean rebuild of the
`eva-swift-stitch` scheme's test target on physical iPad emits
`** TEST BUILD SUCCEEDED **` with zero errors / warnings (excluding the
pre-existing `UIRequiresFullScreen` iOS 26 deprecation warning). All new
test files (`Stage11FamilyBFollowupCalibrationTests`, additions to
`Stage01Tests`, the extracted `TestPixelHelpers.swift`) compile clean
against the new public API surface (`MetalError.textureAllocationFailed`,
`MetalError.noFrameAvailable`, `MetalError: Equatable`, four new
`CaptureDeviceProviding` members). Surfaced one pre-existing test rot
along the way — `Stage09Tests.swift:266` was asserting on a renamed
constant; fixed in the same pass (see `CameraKit/state.md`).

This plan is the punch list for when host-app wiring lands: run the tests
named below, confirm the assertions, then close the ticket.

## Prerequisite

`2026-05-13-camerakit-tests-host-app-wiring.md` must complete first. That plan
fixes the "tool-hosted testing is unavailable on device destinations" failure
mode (CLAUDE.md §8). After it lands:

```bash
mcp__XcodeBuildMCP__test_device   # or scripts/test-summary.sh fallback
```

should run the full CameraKit test suite on the physical iPad. Until then,
runtime behavior of the changes below is unverified.

## Tests to run (all already in repo)

### 1. New error semantics — `MetalError.noFrameAvailable` / `.textureAllocationFailed`

File: `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`
Suite: **`Stage 11 — Family B follow-ups: calibration no-frame semantics`**

| # | Test | Expected |
|---|------|----------|
| 1a | `centerPatchOnNaturalThrowsBeforeFirstFrame` | `dispatchCenterPatchOnNatural()` on a fresh pipeline throws `MetalError.noFrameAvailable`. Pre-rework this would silently fall back to a blank pool buffer and return `(0,0,0)`. |
| 1b | `bbCalibrationSampleThrowsBeforeFirstFrame` | `dispatchBBCalibrationSample()` on a fresh pipeline throws `MetalError.noFrameAvailable`. Pre-rework this threw the less-precise `.unsupportedFormat`. |
| 1c | `centerPatchOnNaturalSamplesInstalledTexture` | After `setLatestNaturalForTest(buffer:texture:)` with a uniform `(0.4, 0.6, 0.2)` fill, `dispatchCenterPatchOnNatural()` returns within 1e-2 of `(0.4, 0.6, 0.2)`. Confirms the new guard doesn't regress the happy path. |
| 1d | `newMetalErrorCasesDistinguishable` | `MetalError.textureAllocationFailed` and `.noFrameAvailable` each match only their own case in a switch. Compile-time + runtime check that the cases aren't accidentally aliased or removed. |

**PASS criterion:** all four pass, no skips, no `Issue.record` calls fire.

### 2. New `CaptureDeviceProviding` surface — `installKVOIngest` / `cancelKVO` / `dumpAllFormats` / `lensAperture`

File: `CameraKit/Tests/CameraKitTests/Stage01Tests.swift`
Suite: existing `Stage01Tests`

| # | Test | Expected |
|---|------|----------|
| 2a | `captureDeviceProviderSeamFamilyBSurface` | On `FakeCaptureDevice`: `lensAperture == 0`, `dumpAllFormats() == []`, `installKVOIngest()` and `cancelKVO()` complete without throwing. Pins the seam contract — any future fake must implement the four new members. |
| 2b | `engineDumpDeviceFormatsReturnsEmptyWhenClosed` | `CameraEngine().dumpDeviceFormats()` on a closed engine returns `[]`. Pre-Family-B follow-up this routed through `as? LiveCaptureDevice`; post-rework it forwards to the protocol's `dumpAllFormats()`. |

**PASS criterion:** both pass.

### 3. Regression: existing Family B tests still green

These are pre-existing tests that exercised the renamed/extracted helpers and
must keep passing:

| File | Suite / Test | Why it matters here |
|------|--------------|---------------------|
| `Stage11Tests.swift` | `Stage 11 — BB calibration scratch encode` / `bbScratchZeroesPedestal` | Uses the renamed `setColorUniformsForTest(_:)`. Pre-rename callers (none, internal) would fail to compile; runtime behavior unchanged. |
| `Stage11Tests.swift` | `…` / `scaledCenterPatchSize` | The `s2 == 30` tightened assertion — confirms the integer math doesn't drift across iOS / Metal updates. |
| `Stage04Tests.swift` | `Stage04Tests` / `colorPipelineGoldenFrame` & `centerPatchTrimmedMean` | Both use the extracted `fillBufferUniform` / `packHalfRGBA` / `HalfPixel` helpers from `TestPixelHelpers.swift`. A mis-extraction would surface as compile failure (already verified) or a regression in numeric output (only verifiable at runtime). |
| `Stage03Tests.swift` | `Stage03Tests` / `kvoAsyncStreamAdapterEmitsOnChange` | Touches `weak var weakObserver`; verifies the documented SourceKit false-positive is still benign and the test still emits one snapshot on KVO change. |

**PASS criterion:** zero regressions vs the pre-rework Stage 11 baseline
(71 passed, 0 failed, 1 skipped — same DEBUG-gated skip).

## Out of scope for this plan

- **`MetalError.textureAllocationFailed`** is not tested at runtime — the
  failure mode requires `MTLDevice.makeTexture` to return `nil`, which is
  hostile-environment-only and not reliably triggerable without device-level
  fault injection. The case is verified by 1d (existence) and by the build
  (the migrated call site at `MetalPipeline.dispatchBBCalibrationSample`
  compiles). Accepted as build-only coverage.

- **Protocol-level `installKVOIngest` / `cancelKVO` semantics on
  `LiveCaptureDevice`** require a real `AVCaptureDevice`, which only exists
  on physical hardware. The fake exercise (2a) covers the seam contract;
  live behavior is implicitly covered by every test that opens a real
  `CameraEngine` (smoke-covered by HITL).

- **`ObservationBox: @unchecked Sendable`** — tracked in followups.md as a
  future-Apple-API contingency, not a code change.

## Runbook (when host-app wiring lands)

1. Run the full test suite: `mcp__XcodeBuildMCP__test_device` (or
   `scripts/test-summary.sh`).
2. Confirm the seven tests above appear in the run (grep the JSON summary
   for the test names).
3. Verify totals match the post-Family-B-followups baseline: **74 passed**
   (71 prior + 3 new in Stage11 + 2 new in Stage01 minus 2 for `1d` and `2a`
   already counted; recount on first green run).
4. If any of 1a–1d, 2a, 2b fail, treat as a Family B follow-up regression
   and revert the specific commit; do not patch around the assertion.
5. Delete the "tests pending verification" note from `CameraKit/state.md`
   (see §Pending runtime test verification block).
