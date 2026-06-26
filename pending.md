# Pending work

Deferred / tracked follow-ups that are intentionally **not** done in the change
that surfaced them. Each entry: what, why deferred, and the acceptance bar.

## Error surface: conform all CameraKit errors to `LocalizedError`

**What.** Make CameraKit's thrown error types — `EngineError`, `MetalError`,
`InteropError`, `RecordingError`, `StillCaptureError` — conform to
`LocalizedError` with proper `errorDescription` (and, where useful,
`failureReason` / `recoverySuggestion`). Single-source those strings and have the
Flutter `asPigeonError()` reuse them (one PigeonError `code` + human-readable
`message` per case) instead of the current duplicated/partial switch.

**Why it matters.** Downstream consumers (the Swift demo and Flutter/Dart apps)
need to understand *what went wrong* — especially for `calibrate*` calls
(black-point / white-balance failures), where the operator must act ("point at a
uniformly dark field"). Today **nothing** in CameraKit conforms to
`LocalizedError`, so `error.localizedDescription` is the opaque default in Swift;
in Flutter only a handful of `EngineError` cases get hardcoded messages and the
rest fall through to `unknownError` + the raw enum-case name.

**Why deferred.** The §4.4 black-balance clean break only does the *mandatory*
slice: it adds a targeted `asPigeonError()` mapping for the new
`EngineError.blackPointCalibrationFailed(reason:)` (without it the Flutter Swift
adapter won't compile) and a `calibrationFailed` Pigeon code. The comprehensive
pass over every error type is its own change.

**Acceptance bar.**
- Every case of the five error enums returns a meaningful `errorDescription`.
- `asPigeonError()` derives its `message` from the error (no duplicated literal
  strings) and maps each case to a sensible `CameraErrorCode`.
- Bare `MetalError` / `CancellationError` thrown from `calibrate*` reach Flutter
  with friendly messages (not `unknownError` + enum-case name).
- Swift: `error.localizedDescription` returns the human-readable string.

Tracked as task #1.

## Consumer docs still describe the removed black-balance API

**What.** The generated consumer docs under `Documentation/` (and their `.docc`
source) still document `calibrateBlackBalance()` and the legacy
`ProcessingParameters.blackR/G/B` as if current — e.g.
`Documentation/reference/camera-engine.md` (two `calibrateBlackBalance()`
sections), `Documentation/reference/image-processing.md` (blackR/G/B fields),
`Documentation/reference/calibration.md`, and the calibration guide source
`CameraKit/Sources/CameraKit/CameraKit.docc/guides/08-calibration.md`.

**Why it matters.** These are user-facing; they'll mislead consumers into calling
a removed API. (Hand-written source/tests are clean — confirmed by a repo-wide
scan; only docs lag.)

**Why deferred.** Regenerating consumer docs (`scripts/regen-docs.sh`) needs a
device symbol-graph build and a manual prose pass over the `.docc` calibration
guide — a distinct chunk from the code clean break.

**Acceptance bar.** No `calibrateBlackBalance` / legacy `blackR/G/B` references in
`Documentation/` or the `.docc` guides; the calibration guide describes black
point. (Historical ledgers — `CameraKit/state.md`, append-only `DECISIONS.md` —
and the `openspec/changes/linear-normalization-stage/` design/spec are records of
the migration and are left as-is, except `tasks.md` §4.4 which is now done.)
