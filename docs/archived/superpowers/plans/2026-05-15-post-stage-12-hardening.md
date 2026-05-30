# Post-Stage-12 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved spec at
`docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md`:
two doc additions (`#6` error routing, `#4` `FrameSet` lifetime), one new
leaf type with migration (`#2` `Mailbox<T>`), one engine state-machine
(`#3+#5` authoritative `SessionState` + transition validator), and one
`DECISIONS.md` entry (`#11`).

**Architecture:** Standalone hardening outside brief discipline. Sequenced
risk-graded (Approach A): docs → Mailbox → engine state machine. Each
deliverable lands as its own commit pending user approval per CLAUDE.md §7.
No behavioral change; pure structural + diagnostic improvement.

**Tech Stack:** Swift 6.2, swift-testing, iOS 26, AVFoundation, Metal.
SwiftPM package + Xcode dual-membership tests (CLAUDE.md §8).

---

## Per-session prep

Do once at start of session, before any task:

- [ ] **P1: Verify XcodeBuildMCP session defaults.**

```
mcp__XcodeBuildMCP__session_show_defaults
```

Expected output names project `eva-swift-stitch.xcodeproj`, scheme
`eva-swift-stitch`, and `deviceId` matching a connected iPad (verify with
`xcrun xctrace list devices`). If unset:

```
mcp__XcodeBuildMCP__session_set_defaults
  project: /Users/shrek/work/cambrian/eva-swift-stitch/eva-swift-stitch.xcodeproj
  scheme:  eva-swift-stitch
  deviceId: <UDID from xctrace list>
```

Never set a simulator destination — CLAUDE.md §6 forbids simulators on
this machine.

- [ ] **P2: Read baseline context (once per session).**

  - `CameraKit/CONTRACTS.md`
  - Tail of `CameraKit/DECISIONS.md`
  - `docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md`
  - This plan

- [ ] **P3: Verify clean baseline build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`. If failure, halt — pre-existing failure must
be diagnosed before any task begins.

**Fallback (only if MCP unavailable per CLAUDE.md §6.1):**
- Build: `scripts/build-summary.sh`
- Test: `scripts/test-summary.sh --filter eva-swift-stitchTests/<SuiteStruct>`

## Commit policy

Per CLAUDE.md §7: every `git commit` step requires explicit user approval
before running. Pre-commit hooks are never skipped (`--no-verify`); signing
is never bypassed. Each task's commit step describes the message; the
executor must pause for user approval before invoking git.

---

### Task 1: Error-routing rule doc (#6)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Errors.swift` (header, before line 1)
- Modify: `CameraKit/DECISIONS.md` (append entry)

- [ ] **Step 1.1: Add the routing-contract header to `Errors.swift`.**

Replace the file's leading `import Foundation` line with:

```swift
import Foundation

// MARK: - Error routing contract
//
// CameraKit has two parallel error surfaces. Route by phase:
//
// 1. Synchronous rejections at the command boundary — caller precondition
//    violations, invalid arguments, .alreadyOpen / .notOpen, alreadyInFlight,
//    invalidOutputPath — surface as typed `EngineError` throws on the
//    suspension point. Caller code handles via `try` / `catch`.
//
// 2. Asynchronous hardware / session / encoding failures — capture device
//    errors, AVCaptureSession runtime errors, AVAssetWriter failures,
//    watchdog firings, max-retries-exceeded — surface as `CameraError` on
//    `errorStream()`. UI subscribes to the stream and routes by `isFatal`.
//
// `EngineError.fatal(CameraError)` bridges (1) → (2) when a synchronous
// path discovers an async-origin fatal condition that already exists as a
// `CameraError` value.
//
// Rationale: synchronous APIs cannot block on future hardware state; async
// failures cannot be observed by a caller that has already returned. The
// surfaces are not interchangeable. Each throw / emit site picks one
// according to its phase, not its severity.
```

- [ ] **Step 1.2: Append entry to `CameraKit/DECISIONS.md`.**

Add to the end of the file (preserve any existing trailing newline):

```markdown

## 2026-05-15 — Error routing rule documented (#6)

Documented the long-standing sync-throw vs. async-stream routing contract
in the `Errors.swift` header. Sync rejections at the command boundary →
typed `EngineError` throw. Async hardware / session / encoding failures →
`CameraError` on `errorStream()`. `EngineError.fatal(CameraError)` is the
bridge. No code change; this codifies what existing throw / emit sites
already do. Post-Stage-12 hardening per
`docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md`.
```

- [ ] **Step 1.3: Verify build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`. Comment-only change — should be zero diagnostics.

- [ ] **Step 1.4: Commit (requires user approval).**

```bash
git add CameraKit/Sources/CameraKit/Errors.swift CameraKit/DECISIONS.md
git commit -m "$(cat <<'EOF'
docs(camerakit): document sync-throw vs async-stream error routing

EngineError covers synchronous command-boundary rejections; CameraError
on errorStream() covers asynchronous hardware/session/encoding failures.
EngineError.fatal(CameraError) bridges. Codifies existing behavior;
no code change. Post-Stage-12 hardening (#6).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `FrameSet` lifetime contract comment (#4)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/FrameSet.swift` (FrameSet struct doc, line 10–21)

- [ ] **Step 2.1: Add the lifetime contract section to the existing FrameSet doc.**

Locate the existing doc comment that begins
`/// Atomic unit of publication per ADR-18.` (around line 10) and ends just
before `public struct FrameSet:`. After the existing `@unchecked Sendable`
paragraph, add a new section. The full replacement doc block:

```swift
/// Atomic unit of publication per ADR-18.
///
/// Stage 06: constructed in `MetalPipeline.addCompletedHandler` from three
/// IOSurface-backed `CVPixelBuffer`s (natural/processed/tracker), the
/// `CMSampleBuffer` capture metadata, and the per-frame `ProcessingMetadata`
/// snapshot from the `Mutex<UniformStorage>` read in `encode()`. Published to
/// subscribed lanes via `ConsumerRegistry.yield(_:stream:)`.
///
/// `@unchecked Sendable` per G-13: `CVPixelBuffer` is not yet `Sendable` on
/// iOS 26; IOSurface backing plus the GPU-completion-before-construction
/// ordering in the completion handler make cross-thread use safe.
///
/// # Lifetime contract
///
/// Consumers must not retain a `FrameSet` (or its `natural` / `processed` /
/// `tracker` `CVPixelBuffer`s) across an `await` or beyond the next stream
/// yield. The buffers are pool-backed (POOL_CAP_RULE); retention exhausts
/// the pool, starves frame delivery, and surfaces three hops away as
/// `frameStall` / watchdog recovery — root cause invisible from the symptom.
///
/// Snapshot any fields you need (`frameNumber`, `captureTime`, `capture`,
/// `processing`, `blurScore`, `trackerQuality`) into your own storage before
/// yielding control. If you need the pixel data itself, copy it under
/// `CVPixelBufferLockBaseAddress` (ADR-06) into your own backing store.
public struct FrameSet: @unchecked Sendable, Hashable {
```

- [ ] **Step 2.2: Verify build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`. Comment-only change.

- [ ] **Step 2.3: Commit (requires user approval).**

```bash
git add CameraKit/Sources/CameraKit/FrameSet.swift
git commit -m "$(cat <<'EOF'
docs(camerakit): document FrameSet lifetime contract

Consumers must not retain a FrameSet or its CVPixelBuffers across an
await or beyond the next stream yield — buffers are pool-backed and
retention exhausts the pool, starving frame delivery. Comment-only.
Post-Stage-12 hardening (#4).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `Mailbox<T>` type + tests (#2 — type)

**Files:**
- Create: `CameraKit/Sources/CameraKit/Mailbox.swift`
- Create: `CameraKit/Tests/CameraKitTests/MailboxTests.swift`

- [ ] **Step 3.1: Create `Mailbox.swift`.**

```swift
import Foundation

/// Single-writer cross-isolation reference cell.
///
/// Names the convention used at every `nonisolated(unsafe)` mailbox site
/// in CameraKit so the safety contract lives once, on the type, instead
/// of being re-cited at each call site.
///
/// # Contract
///
/// - Exactly one writer, on one fixed queue / isolation domain. The owner
///   documents which.
/// - Stored values are pointer-sized references (Swift class / Core
///   Foundation / NSObject) or written exactly once before any read
///   (lazy-init form, e.g. cached stream construction in init).
/// - Readers tolerate seeing the previous or the next reference; tearing
///   is precluded by single-pointer-sized stores.
///
/// # What `Mailbox` does NOT do
///
/// - It adds NO synchronization. The hot path remains identical to the
///   raw `nonisolated(unsafe)` form it replaces.
/// - It does not catch new categories of bug at compile time —
///   `nonisolated(unsafe)` was already explicit.
/// - It does not protect against multi-writer scenarios. If two writers
///   need access from different isolation domains, use an actor or a
///   `Mutex`, not `Mailbox`.
///
/// # Why use it
///
/// The invariant is stated once on the type. The pattern is grepable
/// (`grep 'Mailbox<'`) and reviewable: `mailbox.store(...)` outside the
/// documented writer context is a review smell that raw
/// `nonisolated(unsafe)` provides no syntactic distinction for.
public final class Mailbox<T>: @unchecked Sendable {
    private var _value: T?

    public init(_ initial: T? = nil) {
        self._value = initial
    }

    /// Replace the stored value. Single-writer contract applies — the
    /// owner type documents which queue / isolation domain calls this.
    public func store(_ value: T?) {
        _value = value
    }

    /// Latest stored value, or `nil` before any `store(_:)` call.
    public var latest: T? {
        _value
    }
}
```

- [ ] **Step 3.2: Create `MailboxTests.swift`.**

```swift
import Testing
@testable import CameraKit

@Suite struct MailboxTests {

    @Test("latest is nil before first store")
    func latestNilBeforeStore() {
        let mb = Mailbox<Int>()
        #expect(mb.latest == nil)
    }

    @Test("initial value via init is stored")
    func initialValue() {
        let mb = Mailbox<Int>(7)
        #expect(mb.latest == 7)
    }

    @Test("store then read round-trips")
    func storeThenRead() {
        let mb = Mailbox<Int>()
        mb.store(42)
        #expect(mb.latest == 42)
    }

    @Test("last write wins")
    func lastWriteWins() {
        let mb = Mailbox<Int>()
        mb.store(1)
        mb.store(2)
        mb.store(3)
        #expect(mb.latest == 3)
    }

    @Test("store nil clears")
    func storeNilClears() {
        let mb = Mailbox<Int>()
        mb.store(42)
        mb.store(nil)
        #expect(mb.latest == nil)
    }

    @Test("reference type semantics — two readers see the same updates")
    func referenceTypeSemantics() {
        let mb = Mailbox<Int>()
        let aliased = mb
        mb.store(99)
        #expect(aliased.latest == 99)
    }

    @Test("Sendable witness — usable across Task boundary")
    func sendableWitness() async {
        let mb = Mailbox<Int>(10)
        let result = await Task.detached { mb.latest }.value
        #expect(result == 10)
    }
}
```

- [ ] **Step 3.3: Re-wire the Xcode test target to include the new test file.**

```bash
scripts/sync-test-target.sh
```

Expected: script reports `added: CameraKit/Tests/CameraKitTests/MailboxTests.swift`
(or "no changes" if already wired). Idempotent.

- [ ] **Step 3.4: Build to confirm Mailbox + tests compile.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`.

- [ ] **Step 3.5: Run MailboxTests on device.**

```
mcp__XcodeBuildMCP__test_device
  extraArgs: ["-only-testing:eva-swift-stitchTests/MailboxTests"]
```

Expected: all 7 tests pass. JSON result contains
`"testsCount": 7, "failedCount": 0`.

- [ ] **Step 3.6: Commit (requires user approval).**

```bash
git add CameraKit/Sources/CameraKit/Mailbox.swift \
        CameraKit/Tests/CameraKitTests/MailboxTests.swift \
        eva-swift-stitch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(camerakit): add Mailbox<T> single-writer reference cell

Names the convention at every nonisolated(unsafe) mailbox site so the
safety contract lives once on the type. Adds no synchronization;
adds no compile-time enforcement; makes the pattern grepable and
reviewable. Migration of true mailbox sites follows in subsequent
commits. Post-Stage-12 hardening (#2 — type).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Migrate MetalPipeline mailbox sites (#2 — migration 1/3)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`
  - Sites at lines 87–89 (three `latest*Tex` declarations).
  - Sites at lines 91–93 (three `latest*Buffer` declarations).
  - Every reader / writer of those properties throughout the file.
  - Test seams at lines 875–882 already expose `latestNaturalBufferForTest`
    etc. — these become `latestNaturalBuffer.latest` forwards.

- [ ] **Step 4.1: Replace the three `latest*Tex` declarations.**

Find (around line 85–89):

```swift
    /// `nonisolated(unsafe)` per G-13 / Stage 06 design: two pointer-sized stores
    /// ... existing doc comment ...
    nonisolated(unsafe) private(set) var latestNaturalTex: MTLTexture?
    nonisolated(unsafe) private(set) var latestProcessedTex: MTLTexture?
    nonisolated(unsafe) private(set) var latestTrackerTex: MTLTexture?
```

Replace with:

```swift
    /// Latest texture mailboxes — single writer on the AVF delivery queue
    /// (`addCompletedHandler` callback); readers on MainActor / sessionQueue
    /// / the C++ pixel-sink consumer thread. See `Mailbox<T>` for the
    /// safety contract. G-13 / Stage 06 design.
    ///
    /// Storage is `private` (Mailbox-write access is restricted to this
    /// type); the public-read companion below forwards `latest` so external
    /// readers continue to see `pipeline.latestNaturalTex` returning
    /// `MTLTexture?` — preserves the prior `private(set)` semantics.
    private let _latestNaturalTex = Mailbox<MTLTexture>()
    private let _latestProcessedTex = Mailbox<MTLTexture>()
    private let _latestTrackerTex = Mailbox<MTLTexture>()

    var latestNaturalTex: MTLTexture? { _latestNaturalTex.latest }
    var latestProcessedTex: MTLTexture? { _latestProcessedTex.latest }
    var latestTrackerTex: MTLTexture? { _latestTrackerTex.latest }
```

- [ ] **Step 4.2: Replace the three `latest*Buffer` declarations.**

Find (actual location lines 95–97 — the comment block at 91–94 already
documents the "Phase-2 §2c" rationale, preserve it):

```swift
    nonisolated(unsafe) private(set) var latestNaturalBuffer: CVPixelBuffer?
    nonisolated(unsafe) private(set) var latestProcessedBuffer: CVPixelBuffer?
    nonisolated(unsafe) private(set) var latestTrackerBuffer: CVPixelBuffer?
```

These are `private(set) var` (not `private var`) — externally read by
`CameraEngine.swift:744-746` in `currentPixelBuffer(stream:)`. Apply the
same `_`-prefix private storage + read-only computed-getter pattern as
the Tex trio so external readers keep working unchanged:

```swift
    /// Latest pixel-buffer mailboxes — paired with the texture mailboxes
    /// above. Single writer on the AVF delivery queue; readers wherever
    /// the raw `CVPixelBuffer` is needed (`CameraEngine.currentPixelBuffer`
    /// for the Phase-3 zero-copy FlutterTexture bridge). See `Mailbox<T>`.
    private let _latestNaturalBuffer = Mailbox<CVPixelBuffer>()
    private let _latestProcessedBuffer = Mailbox<CVPixelBuffer>()
    private let _latestTrackerBuffer = Mailbox<CVPixelBuffer>()

    var latestNaturalBuffer: CVPixelBuffer? { _latestNaturalBuffer.latest }
    var latestProcessedBuffer: CVPixelBuffer? { _latestProcessedBuffer.latest }
    var latestTrackerBuffer: CVPixelBuffer? { _latestTrackerBuffer.latest }
```

- [ ] **Step 4.3: Update every writer of all six properties.**

Use grep to find writers:

```bash
grep -n 'latestNaturalTex =\|latestProcessedTex =\|latestTrackerTex =\|latestNaturalBuffer =\|latestProcessedBuffer =\|latestTrackerBuffer =' CameraKit/Sources/CameraKit/MetalPipeline.swift
```

All six properties use the `_`-prefix private-storage pattern after
steps 4.1–4.2; writers go through the `_`-prefixed name:

```swift
// Before:
self.latestNaturalTex = naturalTex
self.latestNaturalBuffer = pb

// After:
self._latestNaturalTex.store(naturalTex)
self._latestNaturalBuffer.store(pb)
```

Apply to every writer site. Writers live entirely within MetalPipeline
(the `addCompletedHandler` body + any encode-path reset paths).

- [ ] **Step 4.4: Verify external readers compile unchanged.**

The computed-getter properties added in steps 4.1–4.2 (`latestNaturalTex`,
`latestProcessedTex`, `latestTrackerTex`, `latestNaturalBuffer`,
`latestProcessedBuffer`, `latestTrackerBuffer`) preserve the prior public
getter shape. External readers — `CameraEngine.swift:716/723/732`
(Tex reads in `currentTexture(stream:)`) and `CameraEngine.swift:744/745/746`
(Buffer reads in `currentPixelBuffer(stream:)`) — continue to work
without modification. Confirm with grep:

```bash
grep -rn 'latestNaturalTex\|latestProcessedTex\|latestTrackerTex\|latestNaturalBuffer\|latestProcessedBuffer\|latestTrackerBuffer' \
    CameraKit/Sources/CameraKit/ eva-swift-stitch/ --include='*.swift'
```

Audit each non-MetalPipeline hit:

- All should be reads (e.g., `_metalPipeline?.latestNaturalBuffer`).
- None should be writes (those live only in MetalPipeline and were
  updated in step 4.3).

If any reader uses a pattern like `pipeline.latestNaturalTex?.someProp`
it continues to work — the computed getter returns `MTLTexture?` /
`CVPixelBuffer?`, identical to the prior `private(set) var` shape.

- [ ] **Step 4.5: Update the test seams at lines 875–882.**

Find:

```swift
    var latestNaturalBufferForTest: CVPixelBuffer? { latestNaturalBuffer }
    var latestProcessedBufferForTest: CVPixelBuffer? { latestProcessedBuffer }
    var latestTrackerBufferForTest: CVPixelBuffer? { latestTrackerBuffer }
```

Replace with:

```swift
    var latestNaturalBufferForTest: CVPixelBuffer? { latestNaturalBuffer.latest }
    var latestProcessedBufferForTest: CVPixelBuffer? { latestProcessedBuffer.latest }
    var latestTrackerBufferForTest: CVPixelBuffer? { latestTrackerBuffer.latest }
```

If `setLatestNaturalForTest(buffer:texture:)` and
`setLatestProcessedForTest(buffer:texture:)` (lines 887–897) do direct
assignments, update them too:

```swift
    func setLatestNaturalForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        latestNaturalBuffer.store(buffer)
        latestNaturalTex.store(texture)
    }

    func setLatestProcessedForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        latestProcessedBuffer.store(buffer)
        latestProcessedTex.store(texture)
    }
```

- [ ] **Step 4.6: Build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`. SourceKit-tagged issues are advisory per
CLAUDE.md §6.1 — trust the build log.

- [ ] **Step 4.7: Run the full CameraKit test suite to confirm no regression.**

```
mcp__XcodeBuildMCP__test_device
```

Expected: all existing tests pass, including the Stage 05 / 06 / 11 / 12
suites that exercise the texture / buffer mailboxes. JSON result
`"failedCount": 0`.

- [ ] **Step 4.8: Commit (requires user approval).**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "$(cat <<'EOF'
refactor(camerakit): migrate MetalPipeline mailboxes to Mailbox<T>

Six single-writer cross-isolation cells (latestNaturalTex/ProcessedTex/
TrackerTex + matching Buffer trio) now use Mailbox<T>. Writers
(AVF delivery queue) call .store(); readers call .latest. No behavioral
change — same single-writer model, same hot-path performance; the
safety invariant is now stated once on Mailbox<T>'s doc rather than
re-cited at six sites. Post-Stage-12 hardening (#2 — migration 1/3).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Migrate DisplayViewModel.trackerTex (#2 — migration 2/3)

**Files:**
- Modify: `eva-swift-stitch/UI/DisplayViewModel.swift` (app-target file —
  the spec/plan inventory's earlier path under `CameraKit/Sources/...`
  was a drift; verified location is the app-target UI directory).
- Modify: `eva-swift-stitch/UI/CameraView.swift` (the single reader).

`Mailbox<T>` is declared `public` in Task 3, so cross-module use from
the app target compiles cleanly without an API-surface change in
CameraKit.

- [ ] **Step 5.1: Locate the trackerTex declaration.**

Find at `eva-swift-stitch/UI/DisplayViewModel.swift:39`:

```swift
    nonisolated(unsafe) var trackerTex: MTLTexture?
```

- [ ] **Step 5.2: Replace with Mailbox.**

```swift
    /// Tracker texture mailbox — single writer (engine delivery via
    /// `attachAfterOpen()` and updates), reader from SwiftUI MTKView
    /// representable. See `Mailbox<T>` (declared in CameraKit).
    let trackerTex = Mailbox<MTLTexture>()
```

- [ ] **Step 5.3: Update every reader / writer of `trackerTex`.**

```bash
grep -n 'trackerTex' eva-swift-stitch/UI/DisplayViewModel.swift
grep -rn 'trackerTex' eva-swift-stitch/UI/ --include='*.swift'
grep -rn 'trackerTex' CameraKit/Sources/CameraKit/ --include='*.swift'
```

For each writer (e.g., `self.trackerTex = tex` inside DisplayViewModel),
replace with `self.trackerTex.store(tex)`.

For the single external reader at
`eva-swift-stitch/UI/CameraView.swift:535`:

```swift
// Before:
textureAccessor: { viewModel.display.trackerTex }

// After:
textureAccessor: { viewModel.display.trackerTex.latest }
```

The closure form means `.latest` substitutes cleanly — the closure's
return type was `MTLTexture?`, and `.latest` returns the same.

If grep surfaces any other reader site (e.g., a `Binding(get:set:)`
form), apply the same `.latest` translation on the read path; on the
write path use `.store(...)`.

- [ ] **Step 5.4: Build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`.

- [ ] **Step 5.5: Run tests.**

```
mcp__XcodeBuildMCP__test_device
```

Expected: all tests pass. JSON `"failedCount": 0`.

- [ ] **Step 5.6: Commit (requires user approval).**

```bash
git add eva-swift-stitch/UI/DisplayViewModel.swift \
        eva-swift-stitch/UI/CameraView.swift
git commit -m "$(cat <<'EOF'
refactor(camerakit): migrate DisplayViewModel.trackerTex to Mailbox<T>

Single-writer (engine via attachAfterOpen) → reader (MTKView
representable) cell now uses Mailbox<T>. Same safety model, invariant
documented once on Mailbox. Post-Stage-12 hardening (#2 — migration 2/3).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Migrate CameraEngine cached streams + `_metalPipeline` (#2 — migration 3/3)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

Six write-once-then-read cells:
- Line 42: `cachedStateStream`
- Line 45: `cachedErrorStream`
- Line 63: `cachedFrameResultStream`
- Line 69: `cachedStreamConfigStream`
- Line 103: `_metalPipeline`
- Line 1184: `cachedRecordingStream`

> Note: the spec listed 5 cached fields; reading the source surfaced a 6th
> (`cachedStreamConfigStream`). Migrating all six for consistency.

- [ ] **Step 6.1: Replace the cached-stream declarations.**

For each of the six lines above, change from:

```swift
nonisolated(unsafe) private var cached<Name>Stream: AsyncStream<...>?
```

to:

```swift
private let cached<Name>Stream = Mailbox<AsyncStream<...>>()
```

Concretely:

```swift
private let cachedStateStream       = Mailbox<AsyncStream<SessionState>>()
private let cachedErrorStream       = Mailbox<AsyncStream<CameraError>>()
private let cachedFrameResultStream = Mailbox<AsyncStream<FrameResult>>()
private let cachedStreamConfigStream = Mailbox<AsyncStream<StreamConfiguration>>()
private let cachedRecordingStream   = Mailbox<AsyncStream<RecordingState>>()
private let _metalPipeline          = Mailbox<MetalPipeline>()
```

Preserve each site's existing nearby comment (the "Bug 5" rationale for
the stream caches, the Bug-4 / G-13 rationale for `_metalPipeline`) —
update its phrasing to reference `Mailbox<T>` instead of
`nonisolated(unsafe)`. Example for the state stream:

```swift
// Bug 5 (docs/stage-11-pre-existing-bugs.md): eagerly constructed in
// init() so the continuation is installed in the box BEFORE any
// publishX(...) can fire. Write-once-before-read mailbox per
// `Mailbox<T>` contract.
private let cachedStateStream = Mailbox<AsyncStream<SessionState>>()
```

- [ ] **Step 6.2: Update each cached-stream initialization in `init()`.**

Find around lines 114–143 (the six `self.cached<Name>Stream = AsyncStream(...)`
assignments inside `init()`). For each, replace:

```swift
self.cached<Name>Stream = AsyncStream<T>(...) { [weak self] continuation in
    self?.<box>.withLock { $0 = continuation }
}
```

with:

```swift
self.cached<Name>Stream.store(AsyncStream<T>(...) { [weak self] continuation in
    self?.<box>.withLock { $0 = continuation }
})
```

(Wrap the existing expression with `.store(...)`.)

- [ ] **Step 6.3: Update each stream-accessor reader.**

The accessor pattern is currently (e.g., `stateStream()` around line 365):

```swift
public func stateStream() -> AsyncStream<SessionState> {
    if let existing = cachedStateStream { return existing }
    // (unreachable post-init — kept defensively)
    let stream = AsyncStream<SessionState>(...) { ... }
    cachedStateStream = stream
    return stream
}
```

Replace with:

```swift
public func stateStream() -> AsyncStream<SessionState> {
    if let existing = cachedStateStream.latest { return existing }
    let stream = AsyncStream<SessionState>(...) { ... }
    cachedStateStream.store(stream)
    return stream
}
```

Apply the same pattern to `errorStream()`, `frameResultStream()`,
`streamConfigStream()`, `recordingStream()`. Grep:

```bash
grep -n 'cachedStateStream\|cachedErrorStream\|cachedFrameResultStream\|cachedStreamConfigStream\|cachedRecordingStream' CameraKit/Sources/CameraKit/CameraEngine.swift
```

- [ ] **Step 6.4: Update every reader / writer of `_metalPipeline`.**

```bash
grep -n '_metalPipeline' CameraKit/Sources/CameraKit/CameraEngine.swift
```

Writers: `self._metalPipeline = pipeline` → `self._metalPipeline.store(pipeline)`.
Writers also include the close-path nil reset:
`self._metalPipeline = nil` → `self._metalPipeline.store(nil)`.
Readers: `_metalPipeline?.<member>` (returning `MetalPipeline?`) →
`_metalPipeline.latest?.<member>`.

> **Important:** `metalPipeline` (no underscore) at `CameraEngine.swift:23`
> is a *parallel* actor-isolated stored field — `private var metalPipeline:
> MetalPipeline?` — written in lock-step with `_metalPipeline` at
> `CameraEngine.swift:232/233`, `387/389`, `618/619`, and `644/645`.
> It is NOT a computed accessor that forwards to `_metalPipeline`. Per
> the migration scope (spec §2 / spec file inventory), only `_metalPipeline`
> migrates to `Mailbox<T>`; leave `metalPipeline` untouched. The
> lock-step pattern is preserved: writes that touch one continue to
> touch the other.

- [ ] **Step 6.5: Build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`.

- [ ] **Step 6.6: Run full test suite.**

```
mcp__XcodeBuildMCP__test_device
```

Expected: all tests pass.

- [ ] **Step 6.7: Commit (requires user approval).**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "$(cat <<'EOF'
refactor(camerakit): migrate CameraEngine mailboxes to Mailbox<T>

Six write-once-then-read cells (cachedStateStream / cachedErrorStream /
cachedFrameResultStream / cachedStreamConfigStream / cachedRecordingStream
/ _metalPipeline) now use Mailbox<T>. Init() stores once; accessors read
via .latest. No behavioral change. Final Mailbox migration site.
Post-Stage-12 hardening (#2 — migration 3/3).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `SessionStateMachine` type + exhaustive tests (#3+#5 — type)

**Files:**
- Create: `CameraKit/Sources/CameraKit/SessionStateMachine.swift`
- Create: `CameraKit/Tests/CameraKitTests/SessionStateMachineTests.swift`

- [ ] **Step 7.1: Create `SessionStateMachine.swift`.**

```swift
import Foundation

/// Authoritative `SessionState` for the engine actor, with an
/// expected-transition classifier.
///
/// # Why not a strict FSM
///
/// `AVCaptureSession` has independent state (`isRunning`, `isInterrupted`,
/// KVO-observable) that the OS mutates asynchronously via
/// `wasInterruptedNotification`, `interruptionEndedNotification`, and
/// `runtimeErrorNotification`. Those are inbound events, not commands.
/// Hard-rejecting off-map transitions could wedge a session on a
/// legitimate-but-rare OS event ordering (e.g. system-pressure
/// interruption followed by a runtime error during the interruption:
/// `.paused → .recovering`, which is rare but legitimate per Apple's
/// model).
///
/// The classifier distinguishes two kinds:
///   - `.command` — host-initiated (open/close/pause/resume) or
///     engine-self-commanded (D-14 self-heal, scenePhase mirror). Strict
///     expected set.
///   - `.event`   — OS-initiated via AVCaptureSession notifications,
///     surfaced by `CameraSession.SessionEvent` and handled in
///     `CameraEngine.onSessionEvent`. Permissive expected set; can arrive
///     from many states.
///
/// Off-map transitions are LOGGED (`CameraKitLog.warning`) with from /
/// to / kind / caller context, then `assertionFailure(...)` in DEBUG,
/// then APPLIED. Observability-first: the state machine is a diagnostic
/// instrument, not a gate. A `paused → recovering` log entry correlated
/// with a preceding OS notification is the legitimate path; the same
/// entry with no OS event in the preceding window is the watchdog-race
/// bug the retrospective predicted.
struct SessionStateMachine {

    /// Classification of the trigger for a transition.
    enum Kind: String, Sendable {
        /// Host-initiated, engine-self-commanded (D-14, scenePhase mirror),
        /// or recovery's natural teardown-and-reopen through `.closed`.
        case command
        /// OS-initiated via AVCaptureSession notification. Originates from
        /// `CameraEngine.onSessionEvent` and from the RecoveryCoordinator
        /// hook (which fires in response to `runtimeErrorNotification`).
        case event
    }

    /// Outcome of classifying a `(from, to, kind)` triple.
    enum Classification: String, Sendable, Equatable {
        case expected
        case offMap
    }

    private(set) var current: SessionState = .closed

    /// Pure classifier — no mutation. Used internally by `transition` and
    /// directly by tests.
    static func classify(
        from: SessionState,
        to: SessionState,
        kind: Kind
    ) -> Classification {
        // Self-transition (re-affirm same state) always expected.
        if from == to { return .expected }
        switch kind {
        case .command:
            return commandMap[from]?.contains(to) == true ? .expected : .offMap
        case .event:
            return eventMap[from]?.contains(to) == true ? .expected : .offMap
        }
    }

    /// Apply a transition. Returns the classification so the caller can
    /// log off-map cases with surrounding context. `current` is updated
    /// regardless of classification (observability-first behavior).
    @discardableResult
    mutating func transition(
        to next: SessionState,
        kind: Kind
    ) -> Classification {
        let cls = Self.classify(from: current, to: next, kind: kind)
        current = next
        return cls
    }

    // MARK: - Expected-transition maps

    /// Command-driven transitions — host-initiated, engine-self-commanded,
    /// or recovery's teardown-and-reopen path through `.closed`.
    ///
    /// `closed → opening` is reserved for the case where the engine
    /// emits `.opening` explicitly before `.streaming`. Today the engine
    /// jumps `closed → streaming` directly inside `open()`; both are
    /// listed as expected so the table accommodates the future state
    /// without immediately producing off-map logs.
    private static let commandMap: [SessionState: Set<SessionState>] = [
        .closed:      [.opening, .streaming],
        .opening:     [.streaming, .closed, .error],
        .streaming:   [.paused, .closed],
        .paused:      [.streaming, .closed],
        .recovering:  [.closed],
        .error:       [.closed],
        .interrupted: [.closed],
    ]

    /// Event-driven transitions — OS-initiated via AVCaptureSession
    /// notifications. The "any → error" pattern is encoded explicitly
    /// per-from-state for clarity.
    private static let eventMap: [SessionState: Set<SessionState>] = [
        .opening:     [.error, .interrupted],
        .streaming:   [.recovering, .error, .paused, .interrupted],
        .paused:      [.streaming, .recovering, .error, .interrupted],
        .recovering:  [.streaming, .error],
        .interrupted: [.streaming, .error],
        .closed:      [.error],
        .error:       [],
    ]

    // MARK: - Test seams

    #if DEBUG
    /// Force-set the current state without classification — for tests
    /// that need to enter a specific state to exercise transitions out
    /// of it without running through the full state space first.
    mutating func _setCurrentForTest(_ state: SessionState) {
        current = state
    }
    #endif
}
```

- [ ] **Step 7.2: Create `SessionStateMachineTests.swift`.**

```swift
import Testing
@testable import CameraKit

@Suite struct SessionStateMachineTests {

    // Hand-enumerated because SessionState is not CaseIterable (public
    // API; we don't add conformance just for tests).
    static let allStates: [SessionState] = [
        .closed, .opening, .streaming, .paused, .recovering, .error, .interrupted,
    ]

    // Expected sets duplicated here on purpose: if production map drifts
    // from the spec, these tests catch it.
    static let expectedCommandMap: [SessionState: Set<SessionState>] = [
        .closed:      [.opening, .streaming],
        .opening:     [.streaming, .closed, .error],
        .streaming:   [.paused, .closed],
        .paused:      [.streaming, .closed],
        .recovering:  [.closed],
        .error:       [.closed],
        .interrupted: [.closed],
    ]

    static let expectedEventMap: [SessionState: Set<SessionState>] = [
        .opening:     [.error, .interrupted],
        .streaming:   [.recovering, .error, .paused, .interrupted],
        .paused:      [.streaming, .recovering, .error, .interrupted],
        .recovering:  [.streaming, .error],
        .interrupted: [.streaming, .error],
        .closed:      [.error],
        .error:       [],
    ]

    @Test("initial current is .closed")
    func initialIsClosed() {
        let sm = SessionStateMachine()
        #expect(sm.current == .closed)
    }

    @Test("transition mutates current regardless of classification")
    func transitionMutatesCurrent() {
        var sm = SessionStateMachine()
        sm.transition(to: .streaming, kind: .command)
        #expect(sm.current == .streaming)
    }

    @Test("expected transition returns .expected and updates current")
    func expectedTransition() {
        var sm = SessionStateMachine()
        let cls = sm.transition(to: .streaming, kind: .command)
        #expect(cls == .expected)
        #expect(sm.current == .streaming)
    }

    @Test("off-map transition returns .offMap but still updates current")
    func offMapStillUpdates() {
        var sm = SessionStateMachine()
        sm._setCurrentForTest(.recovering)
        // recovering → opening is not in either map.
        let cls = sm.transition(to: .opening, kind: .command)
        #expect(cls == .offMap)
        #expect(sm.current == .opening)
    }

    @Test("self-transition is always expected, both kinds")
    func selfTransitionExpected() {
        for state in Self.allStates {
            #expect(
                SessionStateMachine.classify(from: state, to: state, kind: .command)
                    == .expected
            )
            #expect(
                SessionStateMachine.classify(from: state, to: state, kind: .event)
                    == .expected
            )
        }
    }

    @Test(
        "command map: every (from, to) classifies correctly",
        arguments: Self.allStates, Self.allStates
    )
    func commandMapClassification(from: SessionState, to: SessionState) {
        let expected: SessionStateMachine.Classification =
            from == to || Self.expectedCommandMap[from]?.contains(to) == true
                ? .expected : .offMap
        let actual = SessionStateMachine.classify(from: from, to: to, kind: .command)
        #expect(actual == expected,
            "command \(from) → \(to): expected \(expected), got \(actual)")
    }

    @Test(
        "event map: every (from, to) classifies correctly",
        arguments: Self.allStates, Self.allStates
    )
    func eventMapClassification(from: SessionState, to: SessionState) {
        let expected: SessionStateMachine.Classification =
            from == to || Self.expectedEventMap[from]?.contains(to) == true
                ? .expected : .offMap
        let actual = SessionStateMachine.classify(from: from, to: to, kind: .event)
        #expect(actual == expected,
            "event \(from) → \(to): expected \(expected), got \(actual)")
    }
}
```

- [ ] **Step 7.3: Re-wire the Xcode test target.**

```bash
scripts/sync-test-target.sh
```

Expected: `added: CameraKit/Tests/CameraKitTests/SessionStateMachineTests.swift`.

- [ ] **Step 7.4: Build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`.

- [ ] **Step 7.5: Run SessionStateMachineTests.**

```
mcp__XcodeBuildMCP__test_device
  extraArgs: ["-only-testing:eva-swift-stitchTests/SessionStateMachineTests"]
```

Expected: all tests pass. The two parameterized tests each enumerate 49
combinations (7 × 7 states), so total tests is 5 + 49 + 49 = 103 across
the suite.

- [ ] **Step 7.6: Commit (requires user approval).**

```bash
git add CameraKit/Sources/CameraKit/SessionStateMachine.swift \
        CameraKit/Tests/CameraKitTests/SessionStateMachineTests.swift \
        eva-swift-stitch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(camerakit): add SessionStateMachine with expected-transition classifier

Authoritative SessionState container with two-kind classifier (command
vs. event). Off-map transitions are LOGGED + DEBUG-assert + APPLIED —
observability-first, not a gate. Engine adoption follows in next commit.
Exhaustive 7×7 parameterized tests for both classification maps.
Post-Stage-12 hardening (#3 + #5 — type).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `CameraEngine` adopts `SessionStateMachine` (#3+#5 — adoption)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

This task implements the per-call audit, removes stored `isOpen`, and
threads classification through every `publishState` site.

**Audit table — `publishState` sites (verified during plan-writing):**

| Line | Call                                          | Context                          | Kind      |
|------|-----------------------------------------------|----------------------------------|-----------|
| 261  | `publishStateAsync(.recovering)`              | RecoveryCoordinator hook         | `.event`  |
| 311  | `publishState(.streaming)`                    | open() completion                | `.command`|
| 392  | `publishState(.closed)`                       | close()                          | `.command`|
| 495  | `publishState(paused ? .paused : .streaming)` | notifyScenePhasePaused (host)    | `.command`|
| 1333 | `publishState(.paused)`                       | pause() host call                | `.command`|
| 1342 | `publishState(.streaming)`                    | resume() host call               | `.command`|
| 1489 | `publishState(.error)`                        | onSessionEvent .cameraInUseBegan | `.event`  |
| 1502 | `publishState(.interrupted)`                  | onSessionEvent .otherInterruption| `.event`  |
| 1506 | `publishState(.streaming)`                    | onSessionEvent .otherInterruptionEnded | `.event` |

Rule: any `publishState` site reached from inside `onSessionEvent` (the
switch on `CameraSession.SessionEvent`) or via the RecoveryCoordinator
hook is `.event`. All other sites are `.command`. The recovery
teardown-and-reopen path passes through `close() → open()` whose own
publishState calls remain `.command` — the resulting transitions
`.recovering → .closed` and `.closed → .streaming` are both expected
under the command-map, so no kind-threading through `close()`/`open()`
is required.

- [ ] **Step 8.1: Add the state machine and remove stored `isOpen`.**

In `CameraEngine` actor body, near the existing `isOpen` declaration
(around line 46), make these changes:

```swift
// REMOVE:
private var isOpen: Bool = false

// ADD (near top of stored state):
/// Authoritative SessionState — see `SessionStateMachine`.
private var stateMachine = SessionStateMachine()

/// Derived: open if any state other than `.closed`.
///
/// Post-Stage-12 hardening: the prior stored `isOpen: Bool` was a
/// 2-state degenerate view of a 7-case enum; `SessionStateMachine` is
/// now the single source of truth. See DECISIONS entry 2026-05-15.
private var isOpen: Bool { stateMachine.current != .closed }
```

Note: `isOpen` becomes a computed property, *replacing* the stored one.
Every existing `guard isOpen else { ... }` reader continues to work
without modification. Every existing writer (`self.isOpen = true` /
`self.isOpen = false`) must be removed — see steps 8.4 and 8.5.

- [ ] **Step 8.2: Update `publishState` to route through the classifier.**

Find at line 1377:

```swift
private func publishState(_ state: SessionState) {
    stateContinuationBox.withLock { $0?.yield(state) }
}
```

Replace with:

```swift
private func publishState(
    _ state: SessionState,
    kind: SessionStateMachine.Kind,
    function: String = #function
) {
    let from = stateMachine.current
    let classification = stateMachine.transition(to: state, kind: kind)
    if classification == .offMap {
        CameraKitLog.warning(
            .engine,
            "[state] off-map transition from=\(from.rawValue) "
            + "to=\(state.rawValue) kind=\(kind.rawValue) caller=\(function)"
        )
        #if DEBUG
        assertionFailure(
            "off-map SessionState transition: \(from) → \(state) "
            + "(kind=\(kind)) from \(function)"
        )
        #endif
    }
    stateContinuationBox.withLock { $0?.yield(state) }
}
```

- [ ] **Step 8.3: Update `publishStateAsync` to default to `.event`.**

Find at line 1383:

```swift
func publishStateAsync(_ s: SessionState) { publishState(s) }
```

Replace with:

```swift
/// Used by `RecoveryCoordinator.emitStateRecovering` — that hook always
/// fires in response to an OS-driven recovery trigger, hence `.event`.
func publishStateAsync(_ s: SessionState) {
    publishState(s, kind: .event)
}
```

- [ ] **Step 8.4: Update each `publishState(...)` call per the audit table.**

| Line | Current call                                          | Replacement                                                       |
|------|-------------------------------------------------------|-------------------------------------------------------------------|
| 311  | `publishState(.streaming)`                            | `publishState(.streaming, kind: .command)`                        |
| 392  | `publishState(.closed)`                               | `publishState(.closed, kind: .command)`                           |
| 495  | `publishState(paused ? .paused : .streaming)`         | `publishState(paused ? .paused : .streaming, kind: .command)`     |
| 1333 | `publishState(.paused)`                               | `publishState(.paused, kind: .command)`                           |
| 1342 | `publishState(.streaming)`                            | `publishState(.streaming, kind: .command)`                        |
| 1489 | `publishState(.error)`                                | `publishState(.error, kind: .event)`                              |
| 1502 | `publishState(.interrupted)`                          | `publishState(.interrupted, kind: .event)`                        |
| 1506 | `publishState(.streaming)`                            | `publishState(.streaming, kind: .event)`                          |

Line 261 (`publishStateAsync(.recovering)`) is unchanged at the call
site — the helper's default `.event` now applies.

- [ ] **Step 8.5: Remove all stored-`isOpen` writes.**

```bash
grep -n 'self\.isOpen = \|^[[:space:]]*isOpen = ' CameraKit/Sources/CameraKit/CameraEngine.swift
```

Three writer sites — for each, the surrounding context identifies what
to do; line numbers will drift as edits land in earlier steps, so
locate by function name and surrounding logic, not by line:

- Inside `open()`: the `self.isOpen = true` after the session starts
  is now redundant. The `publishState(.streaming, kind: .command)` in
  the same function (the next state-emit after the assignment) advances
  the state machine; the derived `isOpen` flips to `true` automatically.
  **Delete the assignment.**
- Inside `close()`: the `isOpen = false` near the end of teardown is
  redundant. `publishState(.closed, kind: .command)` in the same
  function flips the derived `isOpen` to `false`. **Delete the
  assignment.**
- Inside `_markOpenForTest()`: handled in step 8.6 below; do not delete
  here — replace by the new implementation in 8.6.

- [ ] **Step 8.6: Update `_markOpenForTest()` to advance the state machine.**

Find around line 406:

```swift
func _markOpenForTest() {
    isOpen = true
}
```

Replace with:

```swift
/// Test-only: drive the state machine into a state where teardown paths
/// (`close()` and the `.cameraInUseEnded` self-heal) can be exercised
/// without real hardware. See SessionStateMachine `_setCurrentForTest`
/// for the underlying poke; here we use the public `transition` so the
/// classifier runs and the published stream emits.
func _markOpenForTest() {
    stateMachine._setCurrentForTest(.streaming)
    stateContinuationBox.withLock { $0?.yield(.streaming) }
}
```

> Rationale: this is a test seam that originally bypassed the .opening
> → .streaming path; using `_setCurrentForTest` matches that intent
> (skip classification, set state directly). Tests that rely on the
> seam continue to see `isOpen == true` (since `.streaming != .closed`)
> and a `.streaming` emission on the state stream.

- [ ] **Step 8.7: Build.**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: `BUILD: success`. If `swift-format --strict` (pre-commit)
flags doc-comment line-break issues on the updated `publishState` doc,
add a blank `///` line after the first sentence per CLAUDE.md §8.

- [ ] **Step 8.8: Run the full CameraKit test suite — full regression.**

```
mcp__XcodeBuildMCP__test_device
```

Expected: all existing tests pass — Stage 01 through Stage 12 plus the
new MailboxTests and SessionStateMachineTests. JSON `"failedCount": 0`.

Watch for any test that previously set `isOpen` directly through a
`@testable` import path — none exist per grep, but if a failure
surfaces, update the test to use `_markOpenForTest()` or
`engine.open()`.

- [ ] **Step 8.9: Run on device — visual smoke check (golden path).**

This is a behavioral change to the engine's state machinery; verify
the camera still opens, streams, captures, records, and closes on a
physical iPad. Engineer launches the app once with the patched build
and runs:
1. Open → preview streams.
2. Tap capture → image saved.
3. Long-press record → record → stop. Confirm MP4 lands.
4. Background → foreground → preview still streams.
5. Force-close via app switcher → relaunch → preview streams.

If any path produces an off-map transition log, halt — that's exactly
the diagnostic signal the state machine was added to produce.
Investigate before proceeding to commit.

- [ ] **Step 8.10: Commit (requires user approval).**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "$(cat <<'EOF'
refactor(camerakit): engine adopts SessionStateMachine; isOpen derived

CameraEngine now stores an authoritative SessionState via
SessionStateMachine. Every publishState site classifies its trigger
as .command or .event per the audit in the post-Stage-12 hardening
plan; off-map transitions log + DEBUG-assert + apply
(observability-first). isOpen becomes a computed property over
stateMachine.current. _markOpenForTest uses _setCurrentForTest.
No behavioral change for legal transitions. Post-Stage-12 hardening
(#3 + #5 — adoption).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Post-Stage-12 ledger entries (#11 + closing)

**Files:**
- Modify: `CameraKit/DECISIONS.md` (append entry)
- Modify: `CameraKit/state.md` (prepend post-Stage-12 section)

- [ ] **Step 9.1: Append the engine-authoritative state decision to `DECISIONS.md`.**

```markdown

## 2026-05-15 — Engine-authoritative SessionState (#3 + #5 + #11)

CameraEngine now stores its own SessionState via SessionStateMachine
and is the authoritative source. ViewModel holds a downstream
@Observable mirror updated from stateStream() — used for SwiftUI
invalidation, not as the canonical answer. Synchronous truth is
available to actor-isolated callers via the state machine.

The prior stored `isOpen: Bool` is removed; `isOpen` is now a computed
property (`stateMachine.current != .closed`). sessionToken is unchanged
and remains the identity mechanism for watchdog / D-10 race detection
— different concern from lifecycle, explicitly not folded in.

Every publishState site classifies its trigger as `.command` (host /
engine-self) or `.event` (OS-initiated via onSessionEvent or the
RecoveryCoordinator hook). The classifier consults an
expected-transition map that distinguishes the two kinds; off-map
transitions log + DEBUG-assert + apply (observability-first). The
state machine is a diagnostic instrument: a `paused → recovering` log
correlated with a preceding OS notification is the legitimate
interruption-plus-runtime-error overlap; the same log with no
preceding event is the watchdog-race bug the retrospective predicted.

Post-Stage-12 hardening per
docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md.
```

- [ ] **Step 9.2: Prepend post-Stage-12 section to `state.md`.**

Insert at the very top of `CameraKit/state.md`, *before* the existing
`# state.md — Stage 12` line:

```markdown
# state.md — Post-Stage-12 hardening (2026-05-15)

Standalone hardening effort outside brief discipline. Spec:
`docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md`.
Plan: `docs/superpowers/plans/2026-05-15-post-stage-12-hardening.md`.

## What's built — Post-Stage-12 (permanent)

- **`Mailbox<T>`** at `CameraKit/Sources/CameraKit/Mailbox.swift` — names
  the single-writer cross-isolation reference-cell convention. Migration
  applied to MetalPipeline `latest*Tex` + `latest*Buffer` (6 sites),
  CameraEngine cached streams + `_metalPipeline` (6 sites), and
  DisplayViewModel `trackerTex` (1 site). Other `nonisolated(unsafe)`
  sites (framework-capture, one-shot continuations, log statics,
  test counters, auth provider injection) are explicitly out of scope.
- **`SessionStateMachine`** at
  `CameraKit/Sources/CameraKit/SessionStateMachine.swift` — engine now
  stores authoritative SessionState; publishState routes through
  `transition(to:kind:)` with command / event classification.
  Observability-first off-map policy (log + DEBUG-assert + apply).
- **`isOpen`** is now a derived computed property over
  `stateMachine.current != .closed`. Stored Bool removed.
- **Error routing rule** documented at the top of `Errors.swift` —
  sync rejections throw `EngineError`; async failures emit `CameraError`
  on `errorStream()`.
- **`FrameSet` lifetime contract** documented in `FrameSet.swift` —
  consumers must not retain across `await`; buffers are pool-backed.

## Scaffolding still live

None added; none retired.

## Public API exposed — Post-Stage-12 additions

None. All changes are internal hygiene + structural reorganization.

## Manual test evidence — Post-Stage-12

- HardeningTests (MailboxTests, SessionStateMachineTests) — pass on
  device. SessionStateMachineTests exhaustively covers 7 × 7 = 49
  cells per classification kind.
- Full regression: every prior stage's suite continues to pass.
- Device golden-path smoke (Task 8 step 8.9 of the plan): open →
  stream → capture → record → background-resume → relaunch. No off-map
  transition logs observed during golden-path exercise.

## Decisions taken — Post-Stage-12

See `DECISIONS.md` entries dated 2026-05-15.

## Follow-up consumers (out of scope this PR)

After-#3 payoff sites that internal callers can now lean on:
- `RecoveryCoordinator` could consult `engine.stateMachine.current` via
  a new hook to detect mid-recovery close instead of relying purely on
  `attempt` + external `cancelPendingRetry()`.
- Watchdogs could skip firing during `.paused` / `.recovering` /
  `.interrupted` based on a direct state read rather than `sessionToken`
  comparison.

---

```

(Append three blank lines after the section so the existing
`# state.md — Stage 12` header remains visually separated.)

- [ ] **Step 9.3: Regenerate `CONTRACTS.md` (so the new types appear).**

```bash
scripts/regen-contracts.sh
```

Expected: script runs, `CameraKit/CONTRACTS.md` updates to include
`Mailbox<T>` and `SessionStateMachine`. Verify by grep:

```bash
grep -n 'Mailbox\|SessionStateMachine' CameraKit/CONTRACTS.md
```

Both names should appear under the new-types listing.

- [ ] **Step 9.4: Final full build + test.**

```
mcp__XcodeBuildMCP__build_run_device
mcp__XcodeBuildMCP__test_device
```

Expected: both succeed; no test regression; no new diagnostics.

- [ ] **Step 9.5: Commit (requires user approval).**

```bash
git add CameraKit/DECISIONS.md CameraKit/state.md CameraKit/CONTRACTS.md
git commit -m "$(cat <<'EOF'
docs(camerakit): post-Stage-12 hardening ledger entries

DECISIONS.md: engine-authoritative SessionState (#3 + #5 + #11).
state.md: post-Stage-12 hardening section.
CONTRACTS.md: regenerated to include Mailbox<T> + SessionStateMachine.

Closes the post-Stage-12 hardening pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan-level invariants

- **CLAUDE.md compliance.** Device-only destinations (§6). XcodeBuildMCP
  primary, wrappers fallback (§6.1). swift-format `--strict` is a commit
  gate (§8). Never `--no-verify`. Every commit pending user approval
  (§7). Read CONTRACTS.md once at session start (§6.1).
- **No new `nonisolated(unsafe)` introduced.** All net new declarations
  use `Mailbox<T>` (genuine mailbox sites) or stay actor-isolated.
- **No public API change.** `SessionStateMachine` is internal. `Mailbox<T>`
  is `public` (used in declarations of `public` types' internal storage,
  but Mailbox itself is not exposed through any public method signature).
  `isOpen` was already private — its storage-vs-derived change is invisible
  externally.
- **No behavioral change for legal transitions.** Off-map transitions are
  applied (not rejected) so existing flows that may have silently emitted
  off-table sequences continue to work; they will now log the off-map
  detection for diagnosis.
- **`AVCaptureSession` lifecycle untouched.** `startRunning()` /
  `stopRunning()` continue to run on `sessionQueue` per ADR-07. The
  state machine runs on the engine actor. The two coordinate through
  the existing publish boundaries; they are not coupled directly.
