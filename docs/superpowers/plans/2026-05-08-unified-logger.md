# Unified `CameraKitLog` wrapper — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the duplicated `if isEnabled { Logger.notice(...); CameraKitLog.write(...) }` pattern across CameraKit with a single `CameraKitLog.notice(.engine, "...")`-style call that fans out to OSLog and the file sink, and close the latent gap where `ViewModel.scenePhaseLog` bypasses the file sink entirely.

**Architecture:** Additive-then-delete migration. Add the new wrapper API and `Category` enum to `CameraKitLog` first, leaving the existing public `Logger` properties in place so the build stays green. Migrate the four files one at a time, each ending in a buildable state. Delete the old public surface only after every call site is migrated. Verify on physical iPad via the file sink mirror.

**Tech Stack:** Swift 6, OSLog (`Logger`), `@autoclosure`, XcodeBuildMCP for device builds, `scripts/device-log-live.sh` for log evidence.

**Spec:** `docs/superpowers/specs/2026-05-08-unified-logger-design.md`.

**Build/commit discipline (project rules):**
- Builds go through `mcp__XcodeBuildMCP__build_run_device` (primary) or `scripts/build-summary.sh` (fallback). Never `*_sim`.
- Never run `git commit` / `git add` without explicit user approval. Where a commit step appears, the executor must pause and surface the suggested message to the user.

---

### Task 1: Add the wrapper API to `CameraKitLog` (additive; build stays green)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraKitLog.swift`

- [ ] **Step 1.1: Read the current file**

Read `CameraKit/Sources/CameraKit/CameraKitLog.swift` in full so you have the existing shape (the `Logger` properties, `enableFileLogging()`, `write(_:)`, `timestamp()`) in context before editing.

- [ ] **Step 1.2: Add the `Category` enum + wrapper methods, keep existing surface**

Replace the entire body of `CameraKitLog` with the version below. The four existing `Logger` properties (`engine`, `consumers`, `interop`, `metal`) stay — they will be deleted in Task 5 once every caller is migrated. The file sink (`fileHandle`, `enableFileLogging`, `write`, `timestamp`) stays unchanged.

```swift
import OSLog

/// Centralised logging for CameraKit.
///
/// Off by default. Set `CameraKitLog.isEnabled = true` early in your app
/// (e.g. `App.init`) to enable output in Console.app and the on-device log file.
public enum CameraKitLog {
    // Master switch — write once at app init before any CameraKit actor runs.
    // nonisolated(unsafe): safe because startup write precedes all concurrent reads.
    public nonisolated(unsafe) static var isEnabled: Bool = false

    public enum Category: String {
        case engine, consumers, scenePhase, interop, metal
    }

    // Existing public Loggers — retained during migration, deleted in Task 5.
    static let engine = Logger(subsystem: "com.cambrian.camerakit", category: "engine")
    static let consumers = Logger(subsystem: "com.cambrian.camerakit", category: "consumers")
    static let interop = Logger(subsystem: "com.cambrian.camerakit", category: "interop")
    static let metal = Logger(subsystem: "com.cambrian.camerakit", category: "metal")

    private static let scenePhase = Logger(subsystem: "com.cambrian.camerakit", category: "scenePhase")

    private static func logger(for c: Category) -> Logger {
        switch c {
        case .engine: return engine
        case .consumers: return consumers
        case .scenePhase: return scenePhase
        case .interop: return interop
        case .metal: return metal
        }
    }

    public static func notice(_ c: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: c).notice("\(s, privacy: .public)")
        write("[\(c.rawValue)] \(s)")
    }

    public static func info(_ c: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: c).info("\(s, privacy: .public)")
        write("[\(c.rawValue)] \(s)")
    }

    public static func warning(_ c: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: c).warning("\(s, privacy: .public)")
        write("[\(c.rawValue)] \(s)")
    }

    public static func error(_ c: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: c).error("\(s, privacy: .public)")
        write("[\(c.rawValue)] \(s)")
    }

    // MARK: - File sink (Wi-Fi device, no USB console available)

    // nonisolated(unsafe): written once on init(), read from multiple queues — all after init.
    nonisolated(unsafe) private static var fileHandle: FileHandle?

    /// Opens `<Documents>/camerakit.log` for append and starts mirroring all log
    /// calls to it.
    ///
    /// Call once from `App.init()` alongside setting `isEnabled = true`.
    public static func enableFileLogging() {
        guard
            let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first
        else { return }
        let url = docs.appendingPathComponent("camerakit.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        write("=== CameraKit session started \(Date()) ===")
    }

    static func write(_ message: String) {
        guard isEnabled, let fh = fileHandle else { return }
        let line = "\(timestamp()) \(message)\n"
        fh.write(Data(line.utf8))
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
```

Notes:
- `engine`/`consumers`/`interop`/`metal` are no longer `public` — they were already package-internal in practice (the only callers are inside CameraKit). Dropping `public` here is safe because no out-of-module code references them. If the build complains about access level, restore `public` for now and delete in Task 5.
- `scenePhase` is `private` — it has never been public.
- `write(_:)` stays internal (no `private`) for Task 1; it becomes `private` in Task 5 once nothing outside `CameraKitLog` calls it.

- [ ] **Step 1.3: Build to verify the additive change compiles**

Run via XcodeBuildMCP (project default scheme already configured per session). Build target: physical iPad (or Mac "Designed for iPad" if iPad not connected).

Expected: `BUILD SUCCEEDED`. No call sites changed yet, so no behavioural diff.

If the build fails on the `engine`/`consumers`/`interop`/`metal` access-level demotion, change them back to `public static let` for Task 1 and proceed. Task 5 deletes them entirely.

- [ ] **Step 1.4: Commit checkpoint (pause for user approval)**

Suggested commit message:

```
refactor(logging): add unified CameraKitLog wrapper API

Adds CameraKitLog.notice/.info/.warning/.error(_:_:) with a Category enum.
Existing Logger properties are retained — they will be removed once all call
sites migrate.
```

Pause and ask the user before running `git add` / `git commit`.

---

### Task 2: Migrate `CameraEngine.swift` (4 sites)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` at the four sites listed below

- [ ] **Step 2.1: Read the four target line ranges**

Open `CameraKit/Sources/CameraKit/CameraEngine.swift` and read each block before editing — the surrounding code matters for indentation and for confirming the message contents:

- Lines ~74–76 (open: requesting camera permission)
- Lines ~174–179 (open: pipeline ready — \(w)×\(h))
- Lines ~196–198 (close: tearing down pipeline)
- Lines ~421–429 (getNativePipelineHandle warning + info)

- [ ] **Step 2.2: Replace site 1 — "open: requesting camera permission"**

Old (lines ~74–77):

```swift
if CameraKitLog.isEnabled {
    CameraKitLog.engine.notice("open: requesting camera permission")
    CameraKitLog.write("[engine] open: requesting camera permission")
}
```

New:

```swift
CameraKitLog.notice(.engine, "open: requesting camera permission")
```

- [ ] **Step 2.3: Replace site 2 — "open: pipeline ready" (lines ~174–180)**

Old:

```swift
if CameraKitLog.isEnabled {
    let poolPtr = consumers.nativePipelinePointer()
    let msg =
        "open: pipeline ready — \(captureSize.width)×\(captureSize.height) pool=0x\(String(poolPtr, radix: 16))"
    CameraKitLog.engine.notice("\(msg, privacy: .public)")
    CameraKitLog.write("[engine] \(msg)")
}
```

New (drop the `if isEnabled` and the local `msg`; the `poolPtr` and `String(poolPtr, radix: 16)` calls now live inside the autoclosure and are skipped when `isEnabled == false`):

```swift
CameraKitLog.notice(
    .engine,
    "open: pipeline ready — \(captureSize.width)×\(captureSize.height) pool=0x\(String(consumers.nativePipelinePointer(), radix: 16))"
)
```

If swift-format complains about line length, fall back to a local; the autoclosure semantics are unchanged because `CameraKitLog.notice`'s guard short-circuits before evaluating the message argument:

```swift
let poolPtr = consumers.nativePipelinePointer()
CameraKitLog.notice(
    .engine,
    "open: pipeline ready — \(captureSize.width)×\(captureSize.height) pool=0x\(String(poolPtr, radix: 16))"
)
```

(Trade-off: with the local, the `nativePipelinePointer()` call always runs. Acceptable on a one-shot lifecycle path; not acceptable on a hot path. The hot path in PixelSink Step 3.4 keeps its frame-number throttle precisely for this reason.)

- [ ] **Step 2.4: Replace site 3 — "close: tearing down pipeline"**

Old (lines ~196–199):

```swift
if CameraKitLog.isEnabled {
    CameraKitLog.engine.notice("close: tearing down pipeline")
    CameraKitLog.write("[engine] close: tearing down pipeline")
}
```

New:

```swift
CameraKitLog.notice(.engine, "close: tearing down pipeline")
```

- [ ] **Step 2.5: Replace site 4 — `getNativePipelineHandle` warning + info**

Old (lines ~421–429):

```swift
if CameraKitLog.isEnabled {
    CameraKitLog.engine.warning("getNativePipelineHandle: engine not open — returning nil")
}
// ...
if CameraKitLog.isEnabled {
    let hex = String(ptr, radix: 16)
    CameraKitLog.engine.info("getNativePipelineHandle: 0x\(hex, privacy: .public)")
}
```

New:

```swift
CameraKitLog.warning(.engine, "getNativePipelineHandle: engine not open — returning nil")
// ...
CameraKitLog.info(.engine, "getNativePipelineHandle: 0x\(String(ptr, radix: 16))")
```

The `String(ptr, radix: 16)` runs inside the autoclosure, so it's skipped when `isEnabled == false`. The `\(hex, privacy: .public)` OSLog interpolation is replaced by plain string interpolation — the wrapper applies `privacy: .public` to the whole message.

- [ ] **Step 2.6: Build to verify all four sites compile**

Run via XcodeBuildMCP `build_run_device`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2.7: Commit checkpoint (pause for user approval)**

Suggested commit message:

```
refactor(logging): migrate CameraEngine to CameraKitLog wrapper
```

Pause for user approval.

---

### Task 3: Migrate `PixelSink.swift` (3 sites)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/PixelSink.swift` at the three sites listed below

- [ ] **Step 3.1: Read the three target line ranges**

Read each block before editing:
- Lines ~137–141 (registerCallback)
- Lines ~163–167 (unregister)
- Lines ~213–218 (per-300-frame yield stats; `.info` level)

- [ ] **Step 3.2: Replace site 1 — registerCallback (lines ~137–142)**

Old:

```swift
if CameraKitLog.isEnabled {
    let msg =
        "registerCallback: stream=\(stream.rawPoolId) token=\(token) cppCount=\(self.cppPool.consumerCount(stream: stream.rawPoolId))"
    CameraKitLog.consumers.notice("\(msg, privacy: .public)")
    CameraKitLog.write("[consumers] \(msg)")
}
```

New:

```swift
CameraKitLog.notice(
    .consumers,
    "registerCallback: stream=\(stream.rawPoolId) token=\(token) cppCount=\(self.cppPool.consumerCount(stream: stream.rawPoolId))"
)
```

The `consumerCount` call now lives inside the autoclosure — skipped entirely when `isEnabled == false`.

- [ ] **Step 3.3: Replace site 2 — unregister (lines ~163–168)**

Old:

```swift
if CameraKitLog.isEnabled {
    let msg =
        "unregister: token=\(token.id) stream=\(token.stream.rawPoolId) lane=\(foundSwift ? "swift" : "cpp")"
    CameraKitLog.consumers.notice("\(msg, privacy: .public)")
    CameraKitLog.write("[consumers] \(msg)")
}
```

New:

```swift
CameraKitLog.notice(
    .consumers,
    "unregister: token=\(token.id) stream=\(token.stream.rawPoolId) lane=\(foundSwift ? "swift" : "cpp")"
)
```

- [ ] **Step 3.4: Replace site 3 — per-300-frame yield stats (lines ~213–219)**

Old:

```swift
// Throttle: log every 300 frames (~10 s at 30 fps) to avoid flooding.
if CameraKitLog.isEnabled && frameSet.frameNumber % 300 == 0 {
    let hasSurface = surface != nil
    let msg =
        "yield: frame=\(frameSet.frameNumber) stream=\(stream.rawPoolId) surface=\(hasSurface) cppConsumers=\(self.cppPool.consumerCount(stream: stream.rawPoolId))"
    CameraKitLog.consumers.info("\(msg, privacy: .public)")
    CameraKitLog.write("[consumers] \(msg)")
}
```

New (preserve the `% 300 == 0` throttle — that's the hot-path guard, separate from `isEnabled`):

```swift
// Throttle: log every 300 frames (~10 s at 30 fps) to avoid flooding.
if frameSet.frameNumber % 300 == 0 {
    let hasSurface = surface != nil
    CameraKitLog.info(
        .consumers,
        "yield: frame=\(frameSet.frameNumber) stream=\(stream.rawPoolId) surface=\(hasSurface) cppConsumers=\(self.cppPool.consumerCount(stream: stream.rawPoolId))"
    )
}
```

The frame-number throttle stays outside the wrapper because it's the explicit hot-path gate (every 300th frame ≈ once per 10s @ 30fps). The wrapper's `isEnabled` check is a separate concern. `hasSurface` stays as a local because it's used in a Bool comparison; the `consumerCount` call is now lazy via the autoclosure.

- [ ] **Step 3.5: Build**

XcodeBuildMCP `build_run_device`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3.6: Commit checkpoint (pause for user approval)**

Suggested commit message:

```
refactor(logging): migrate PixelSink to CameraKitLog wrapper
```

---

### Task 4: Migrate `ViewModel.swift` and delete the orphan `scenePhaseLog`

This task closes the latent bug where scenePhase transitions never reach the file sink.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/ViewModel.swift`

- [ ] **Step 4.1: Read the file**

Read `CameraKit/Sources/CameraKit/ViewModel.swift` in full (it's small enough) so you have line 7 (`scenePhaseLog` declaration) and lines ~228–254 (the `handleScenePhase` body) in context.

- [ ] **Step 4.2: Delete the file-scope `scenePhaseLog` declaration**

Delete line 7:

```swift
private let scenePhaseLog = Logger(subsystem: "com.cambrian.camerakit", category: "scenePhase")
```

The `import OSLog` on line 4 stays — `Logger` is still imported transitively, but more importantly the file may use other OSLog APIs in future stages. Leaving the import in place is harmless.

- [ ] **Step 4.3: Replace the four `scenePhaseLog.notice` calls in `handleScenePhase`**

Old block (lines ~229–248):

```swift
let prev = String(describing: self.previousPhase)
let next = String(describing: phase)
scenePhaseLog.notice("scenePhase: \(prev, privacy: .public) → \(next, privacy: .public)")
switch phase {
case .inactive:
    await engine.setGate(false)
    await engine.drainSubmittedFrame()
    scenePhaseLog.notice("scenePhase inactive: gate closed, drain complete")

case .background:
    await engine.backgroundSuspend()
    scenePhaseLog.notice("scenePhase background: backgroundSuspend complete")

case .active:
    if previousPhase == .background {
        await engine.backgroundResume()
    }
    await engine.setGate(true)
    let prev = String(describing: self.previousPhase)
    scenePhaseLog.notice("scenePhase active: gate open (prevPhase=\(prev, privacy: .public))")

@unknown default:
    break
}
```

New:

```swift
let prev = String(describing: self.previousPhase)
let next = String(describing: phase)
CameraKitLog.notice(.scenePhase, "scenePhase: \(prev) → \(next)")
switch phase {
case .inactive:
    await engine.setGate(false)
    await engine.drainSubmittedFrame()
    CameraKitLog.notice(.scenePhase, "scenePhase inactive: gate closed, drain complete")

case .background:
    await engine.backgroundSuspend()
    CameraKitLog.notice(.scenePhase, "scenePhase background: backgroundSuspend complete")

case .active:
    if previousPhase == .background {
        await engine.backgroundResume()
    }
    await engine.setGate(true)
    let prevActive = String(describing: self.previousPhase)
    CameraKitLog.notice(.scenePhase, "scenePhase active: gate open (prevPhase=\(prevActive))")

@unknown default:
    break
}
```

Notes on the rewrite:
- `\(prev, privacy: .public)` becomes plain `\(prev)` — the wrapper applies `.public` to the whole message.
- The `.active` arm originally shadowed `prev` with a second `let prev = ...`. That was a line-length workaround. Renamed to `prevActive` to remove the shadow; same semantics.
- Line lengths stay well under 120 cols without the `privacy: .public` markers, so the original line-splitting hacks (the two-line `let prev = ...; scenePhaseLog.notice(...)` pattern) are no longer needed.

- [ ] **Step 4.4: Build**

XcodeBuildMCP `build_run_device`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4.5: Commit checkpoint (pause for user approval)**

Suggested commit message:

```
refactor(logging): migrate ViewModel scenePhase to CameraKitLog wrapper

Closes the gap where scenePhase transitions were logged to OSLog only and
never reached the file sink. The orphan file-scope Logger is gone; all
scenePhase output now flows through CameraKitLog.notice(.scenePhase, ...).
```

---

### Task 5: Delete the legacy `Logger` properties and tighten access

With every caller migrated, the old surface can go.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraKitLog.swift`

- [ ] **Step 5.1: Verify zero callers reference the old surface**

Run from the repo root:

```bash
grep -rn 'CameraKitLog\.\(engine\|consumers\|interop\|metal\)\b' \
  /Users/shrek/work/cambrian/eva-swift-stitch/.claude/worktrees/logging/CameraKit/Sources/
grep -rn 'scenePhaseLog' \
  /Users/shrek/work/cambrian/eva-swift-stitch/.claude/worktrees/logging/CameraKit/Sources/
grep -rn 'CameraKitLog\.write\b' \
  /Users/shrek/work/cambrian/eva-swift-stitch/.claude/worktrees/logging/CameraKit/Sources/
```

Expected: zero hits for all three. If any hit appears, fix the call site (move it to the wrapper) before continuing.

- [ ] **Step 5.2: Delete the four `Logger` properties and make `write(_:)` private**

Open `CameraKit/Sources/CameraKit/CameraKitLog.swift` and delete:

```swift
static let engine = Logger(subsystem: "com.cambrian.camerakit", category: "engine")
static let consumers = Logger(subsystem: "com.cambrian.camerakit", category: "consumers")
static let interop = Logger(subsystem: "com.cambrian.camerakit", category: "interop")
static let metal = Logger(subsystem: "com.cambrian.camerakit", category: "metal")
```

Move the now-private `Logger` instances into `logger(for:)` as locally-scoped statics, or keep them as `private static let` on the type. The cleanest version:

```swift
private enum Loggers {
    static let engine = Logger(subsystem: "com.cambrian.camerakit", category: "engine")
    static let consumers = Logger(subsystem: "com.cambrian.camerakit", category: "consumers")
    static let scenePhase = Logger(subsystem: "com.cambrian.camerakit", category: "scenePhase")
    static let interop = Logger(subsystem: "com.cambrian.camerakit", category: "interop")
    static let metal = Logger(subsystem: "com.cambrian.camerakit", category: "metal")
}

private static func logger(for c: Category) -> Logger {
    switch c {
    case .engine: return Loggers.engine
    case .consumers: return Loggers.consumers
    case .scenePhase: return Loggers.scenePhase
    case .interop: return Loggers.interop
    case .metal: return Loggers.metal
    }
}
```

Then change `write(_:)`:

```swift
private static func write(_ message: String) {
    guard isEnabled, let fh = fileHandle else { return }
    let line = "\(timestamp()) \(message)\n"
    fh.write(Data(line.utf8))
}
```

(Also delete the standalone `private static let scenePhase = ...` you added in Task 1 — it's superseded by `Loggers.scenePhase`.)

- [ ] **Step 5.3: Build**

XcodeBuildMCP `build_run_device`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5.4: Re-run scaffold-coherence preflight**

Run `scripts/stage-preflight.sh`. Expected: exit 0. The refactor is intra-Stage-08, so no scaffold slugs change; the preflight check is just a smoke test that nothing else regressed.

- [ ] **Step 5.5: Commit checkpoint (pause for user approval)**

Suggested commit message:

```
refactor(logging): remove legacy CameraKitLog Logger properties

Every caller now uses CameraKitLog.notice/.info/.warning/.error(_:_:).
Drops the four public Logger statics and seals `write` as private.
```

---

### Task 6: Device verification — close the latent scenePhase bug

This task produces the evidence that the refactor not only compiles but actually fixed the file-sink gap.

**Files:**
- (no source changes)

- [ ] **Step 6.1: Build & install on physical iPad**

Use `mcp__XcodeBuildMCP__build_run_device`. Expected: app launches on the iPad. Confirm the Metal preview is visible (sanity check that nothing else regressed).

- [ ] **Step 6.2: Start the live log mirror**

```bash
scripts/device-log-live.sh
```

Wait ~6 seconds for the first poll. Expect output `started polling, mirror at /var/folders/.../T/camerakit-live.log`.

- [ ] **Step 6.3: Trigger a few scenePhase transitions**

On the iPad: swipe the app to the multitasking carousel and back twice (active → inactive → active → background → active). Each transition produces ≥1 log line.

- [ ] **Step 6.4: Verify scenePhase entries reach the file sink**

```bash
scripts/device-log-live.sh grep "scenePhase"
```

Expected: at least 4 lines tagged `[scenePhase]`, e.g.

```
14:05:17.231 [scenePhase] scenePhase: active → inactive
14:05:17.234 [scenePhase] scenePhase inactive: gate closed, drain complete
14:05:18.044 [scenePhase] scenePhase: inactive → active
14:05:18.046 [scenePhase] scenePhase active: gate open (prevPhase=inactive)
```

This is the proof point — pre-refactor these lines never appeared in the file.

- [ ] **Step 6.5: Sanity-check engine and consumers categories also still log**

```bash
scripts/device-log-live.sh grep '\[engine\]'
scripts/device-log-live.sh grep '\[consumers\]'
```

Expected: each returns at least one line (the `engine` open lifecycle, the `consumers` register/unregister or yield stats).

- [ ] **Step 6.6: Stop the mirror**

```bash
scripts/device-log-live.sh stop
```

- [ ] **Step 6.7: No commit needed**

This task is verification only. If steps 6.4 or 6.5 fail, return to the relevant earlier task — the wrapper isn't faning out correctly.

---

## Risks & guard-rails recap

- **Per-step build**: every code-changing task ends with a build. A red build halts the chain.
- **No tests modified**: `CameraKitLog` has no coverage today. The refactor's correctness is verified at build time (compiler enforces the new shape) and at runtime via Task 6's device evidence.
- **Commit gating**: every commit step pauses for user approval. The executor must not run `git commit` autonomously.
- **`isEnabled` semantics for scenePhase**: the four `scenePhase` calls now obey `isEnabled` like every other category. In practice, `App.init` sets `isEnabled = true` alongside `enableFileLogging()`, so this is invisible. Documented in the spec.
