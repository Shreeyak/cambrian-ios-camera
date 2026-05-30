# Unified `CameraKitLog` wrapper — design

## Problem

Every CameraKit log call site repeats a five-line dual-sink pattern:

```swift
if CameraKitLog.isEnabled {
    let msg = "open: pipeline ready — \(w)×\(h)"
    CameraKitLog.engine.notice("\(msg, privacy: .public)")
    CameraKitLog.write("[engine] \(msg)")
}
```

This costs three things:

1. **Boilerplate.** ~10 paired sites today, growing every stage.
2. **Drift.** `ViewModel.scenePhaseLog` was added as its own `Logger` and never wired
   to the file sink — a latent bug. Any new module is one copy-paste away from
   the same omission.
3. **Lost work when disabled.** The `if isEnabled` guards each site, but the
   string is still constructed inside the `if`. The guard is correct; the call
   sites just hide the work behind a condition rather than deferring it.

## Goal

One call site per log event. File sink and `OSLog` stay synchronised. Disabled
state pays zero string-construction cost.

Non-goals: persisting `OSLog` archives, adding remote sinks, log rotation,
multi-process coordination.

## API

```swift
public enum CameraKitLog {
    public enum Category: String {
        case engine, consumers, scenePhase, interop, metal
    }

    public nonisolated(unsafe) static var isEnabled: Bool = false

    public static func enableFileLogging() { … }     // unchanged

    public static func notice(_ c: Category, _ msg: @autoclosure () -> String)
    public static func info(_ c: Category, _ msg: @autoclosure () -> String)
    public static func warning(_ c: Category, _ msg: @autoclosure () -> String)
    public static func error(_ c: Category, _ msg: @autoclosure () -> String)
}
```

Each method:

```swift
public static func notice(_ c: Category, _ msg: @autoclosure () -> String) {
    guard isEnabled else { return }
    let s = msg()
    logger(for: c).notice("\(s, privacy: .public)")
    write("[\(c.rawValue)] \(s)")
}
```

`logger(for:)` is a private switch over `Category` returning the cached
`Logger` instance. The four existing public `Logger` properties
(`engine`, `consumers`, `interop`, `metal`) are deleted; the wrapper is the
only path.

### Why `@autoclosure`

When `isEnabled == false`, the closure body is never evaluated — string
interpolation, integer formatting, `String(describing:)` calls all skipped.
The caller writes natural Swift; the deferral is invisible at the call site.

### Why per-level methods over a single `log(level:…)`

Mirrors `Logger`'s own surface. Each method statically dispatches to the
matching `Logger.notice`/`.info`/`.warning`/`.error`, no runtime switch on
level. Call sites stay short.

### Trade-off accepted

Per-field privacy markers (`\(value, privacy: .private)`) and OSLog format
specifiers (`\(int, format: .hex)`) are not reachable through the wrapper —
the body becomes a plain `String` before it crosses into `OSLogMessage`. This
is fine for current content, which is non-PII telemetry already marked
`.public`, with hex/decimal formatting done before the call (e.g. the
existing `String(ptr, radix: 16)` pattern). If a real privacy-sensitive
field appears later, we add a targeted method then.

## Call-site shape after refactor

```swift
// before (5 lines)
if CameraKitLog.isEnabled {
    let msg = "open: pipeline ready — \(w)×\(h)"
    CameraKitLog.engine.notice("\(msg, privacy: .public)")
    CameraKitLog.write("[engine] \(msg)")
}

// after (1 line)
CameraKitLog.notice(.engine, "open: pipeline ready — \(w)×\(h)")
```

## Files touched

- **`CameraKit/Sources/CameraKit/CameraKitLog.swift`** — add `Category` enum
  and the four wrapper methods; delete the four public `Logger` properties;
  make `write(_:)` private.
- **`CameraKit/Sources/CameraKit/CameraEngine.swift`** — collapse 4 paired
  sites (lines ~74, ~174, ~196, ~421/427) to single calls.
- **`CameraKit/Sources/CameraKit/PixelSink.swift`** — collapse 3 paired sites
  (lines ~137, ~163, ~213).
- **`CameraKit/Sources/CameraKit/ViewModel.swift`** — delete the private
  `scenePhaseLog`; replace 4 `scenePhaseLog.notice` calls with
  `CameraKitLog.notice(.scenePhase, …)`. This also closes the file-sink gap.

No tests touched — `CameraKitLog` has no test coverage today and the
refactor is behaviourally equivalent for `isEnabled == true`. A follow-up
spec can add coverage if needed.

## Verification

1. `mcp__XcodeBuildMCP__build_run_device` succeeds (device-only per CLAUDE.md §6).
2. `grep -rn "CameraKitLog\.\(engine\|consumers\|interop\|metal\)\b" CameraKit/Sources/`
   returns zero hits — proves the old surface is gone.
3. `grep -rn "scenePhaseLog" CameraKit/Sources/` returns zero hits.
4. With the app running on the iPad, `scripts/device-log-live.sh grep
   "scenePhase"` returns lines tagged `[scenePhase]` — proves the latent
   bug is closed.

## Risks

- **Behaviour change for `scenePhase`.** The current `scenePhaseLog.notice`
  calls fire unconditionally; after the refactor they go through the
  `isEnabled` gate like every other category. In practice the app turns
  `isEnabled = true` in `App.init` alongside `enableFileLogging()`, so the
  gate is open whenever the app runs — but a developer toggling `isEnabled`
  off at runtime would lose scenePhase output too. Acceptable: that
  consistency is the point of the refactor.
- **Concurrency.** All wrapper methods are `nonisolated`; `Logger` is
  `Sendable`; `FileHandle.write` is documented thread-safe for `Data`. No
  new isolation concerns introduced.
