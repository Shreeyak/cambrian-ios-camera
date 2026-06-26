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

## Finish the remove-natural-lane Flutter port

**What.** Remove the dangling natural-lane references from the Flutter layer:
`SessionCapabilities.naturalTextureId` in the Pigeon DSL (+ regen), the adapter's
`ValueTypeMappers.swift` mapping (~line 152), and the stale
`StreamId.processed/.natural` usages in `camera_engine_texture_test.dart`,
`camera_engine_open_close_test.dart`, and `example/integration_test/plugin_test.dart`.

**Why deferred.** CameraKit's `remove-natural-lane` migration dropped the natural
lane and renamed `StreamId` to `{primary, tracker}`, but the Flutter port was
never finished — so `flutter build ios` and the Dart texture test have been red
since *before* the black-balance clean break, for an unrelated reason. Fixing it
is the natural-lane migration's concern, not the black-point change's.

**Impact now.** The black-point Flutter wiring is complete and correct (Dart unit
tests pass; the Swift adapter signatures match the regenerated Pigeon protocol),
but the Flutter iOS plugin cannot be *build-verified* until this debt is cleared.

**Acceptance bar.** `flutter build ios` and `flutter test` both green.

Tracked as task #5.
