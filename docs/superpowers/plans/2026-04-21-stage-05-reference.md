# Stage 05 Implementation Reference — Mutex<UniformStorage> + per-frame snapshot

**Companion to:** the Stage 05 implementation plan. Read both before editing code.

**Purpose:** verified API signatures, idiomatic patterns, gotchas, and brief deviations specific to Stage 05. Implementation agents should consult this file before Task 4 (`MetalPipeline` lock integration).

**Lock choice — read this first:** Stage 05 uses `Synchronization.Mutex<UniformStorage>` (iOS 18+), **not** `OSAllocatedUnfairLock<UniformStorage>` as named in D-17. This is a **user-authorized override** of the upstream architecture decision. Rationale: Mutex is the preferred Swift 6+ primitive per `all-ios-skills:swift-concurrency`; its `withLock`-only API (no manual `lock()`/`unlock()`) structurally prevents holding the lock across commit — the "Inv 6 can't be violated" guarantee becomes a type-system property rather than a runtime assertion. If a future stage ever has to support iOS < 18 (extremely unlikely given this project targets iOS 26), swap back to OSAllocatedUnfairLock and add the debug-counter-based runtime check.

**Sources:**
- Apple docs (via `mcp__dash-api__load_documentation_page`, docset `tkaubcqb-swift`, on 2026-04-21)
- `all-ios-skills:swift-concurrency` skill
- `all-ios-skills:swift-testing` skill
- `implementation/briefs/stage-05.md` (authoritative)
- `implementation/architecture/02-concurrency.md` §D-17
- `implementation/architecture/04-metal-pipeline.md` §Shader uniforms + §Command graph
- `/Users/shrek/work/cambrian/eva-swift-stitch/CLAUDE.md`

---

## 1. Verified Apple API signatures

### `Synchronization.Mutex<Value>` — iOS 18+ (our chosen lock)

Verified from `https://developer.apple.com/documentation/synchronization/mutex`.

```swift
@frozen struct Mutex<Value> where Value: ~Copyable
    // Conforms to Sendable, SendableMetatype.
    // NOTE: the `Value: ~Copyable` constraint relaxes the Copyable requirement.
    // Copyable types (including our UniformStorage) satisfy `~Copyable` too —
    // they're a subset of the generalized constraint.

// Constructor:
init(_ initialValue: consuming sending Value)
    // `consuming` — Mutex takes ownership of the argument.
    // `sending` — argument can safely cross isolation domains during init.

// Scoped acquisition (the ONLY public locking API — no manual lock/unlock):
borrowing func withLock<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
) throws(E) -> sending Result
    where E: Error, Result: ~Copyable

borrowing func withLockIfAvailable<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
) throws(E) -> sending Result?
    where E: Error, Result: ~Copyable
```

**Key semantics:**
- **No public `lock()` / `unlock()` methods.** Exclusive access is ONLY available via `withLock`. This is the type-level guarantee that the lock cannot be held across commit.
- **Body closure uses `inout sending Value`.** The value is inout-accessible inside the closure; sending means it's ownership-transferred. For Copyable Value types this is invisible — you read/write fields normally.
- **Return type uses `sending Result`.** When you do `lock.withLock { $0 }` to snapshot, the returned Value is "sent" — the caller owns it independently. For Copyable types this is a plain copy; no visible syntax.
- **Typed throws `throws(E)`.** Mutex propagates the body's typed error. Our uses don't throw; `throws(Never)` collapses to non-throwing.
- **Lock is released when the closure returns, always.** No way to leak ownership across commit, encoder lifetime, or await.
- **Does NOT have ownership-assertion API** (unlike OSAllocatedUnfairLock's `precondition(.owner/.notOwner)`). Not needed — the type prevents the misuse that assertion would catch.

### `os.OSAllocatedUnfairLock<State>` — iOS 16+ (NOT used; reference only)

We do **not** use OSAllocatedUnfairLock. Documented here so implementers know what's in D-17 and why we diverge. Signature for context:

```swift
@frozen struct OSAllocatedUnfairLock<State>
init(initialState: State)
func withLock<R>(_ body: @Sendable (inout State) throws -> R) rethrows -> R where R: Sendable
func lock()     // exists — can leak across any boundary
func unlock()   // exists — programmer must pair correctly
func precondition(_ condition: Ownership)  // runtime ownership assertion
enum Ownership { case owner, notOwner }
```

The exposure of manual `lock()` / `unlock()` is exactly the attack surface we eliminate by choosing Mutex.

### `Metal.MTLDevice.makeBuffer(bytes:length:options:)` — iOS 8+

Verified from `https://developer.apple.com/documentation/metal/mtldevice/makebuffer(bytes:length:options:)`.

```swift
func makeBuffer(
    bytes pointer: UnsafeRawPointer,
    length: Int,
    options: MTLResourceOptions = []
) -> (any MTLBuffer)?
```

**Key semantics:**
- **Copies `length` bytes** from `pointer` into the newly allocated buffer. The source memory can be freed/reused immediately after this returns.
- **Returns optional** — allocation can fail (rare, but must be `guard let`-handled).
- **Use `MTLResourceOptions.storageModeShared`** for CPU-written uniforms on Apple Silicon — no explicit synchronization required between CPU write and GPU read.

### `Metal.MTLComputeCommandEncoder.setBuffer(_:offset:index:)`

Verified from `https://developer.apple.com/documentation/metal/mtlcomputecommandencoder/setbuffer(_:offset:index:)`.

```swift
func setBuffer(_ buffer: (any MTLBuffer)?, offset: Int, index: Int)
```

**Key semantics:**
- **Metal retains the buffer through the command buffer's lifetime** — the Swift local variable can go out of scope after `setBuffer` returns. Do not attempt to optimize with `withUnsafeBytes` or unchecked pointers.

### `DispatchQueue.concurrentPerform(iterations:execute:)` — all platforms

Verified from `https://developer.apple.com/documentation/dispatch/dispatchqueue/concurrentperform(iterations:execute:)`.

```swift
static func concurrentPerform(iterations: Int, execute work: (Int) -> Void)
```

**Key semantics:**
- **Synchronous** — blocks the calling thread until every iteration completes.
- **Implicit parallelism** — iterations are distributed across the concurrent queue; level of parallelism is system-decided.
- **Not compatible with `async` contexts directly** — if invoked from an `async` test body, you may need to wrap it or pair it with `Task.detached` for the concurrent reader (see stress-test pattern below).


---

## 2. Idiomatic patterns for Stage 05

### Writer on the engine actor

```swift
// CameraEngine.swift — setProcessingParameters
public func setProcessingParameters(_ params: ProcessingParameters) async {
    metalPipeline?.uniformsLock.withLock { $0.color = ColorUniform(params) }
    let toSave = params
    Task.detached { SettingsPersistence.saveProcessing(toSave) }
}
```

**Why this shape:** optional-chaining on `metalPipeline?` short-circuits if the pipeline is not yet created; the lock write is synchronous (no await between it and the Task.detached dispatch), so actor reentrancy cannot observe a partial state.

### Snapshot on the delivery queue

```swift
// MetalPipeline.swift — encode()
let snapshot = uniformsLock.withLock { $0 }
let colorSnapshot = snapshot.color
let cropSnapshot  = snapshot.crop
```

**Why this shape:** closure returns on the same thread, releasing the lock synchronously. The returned `UniformStorage` is a value copy — subsequent mutations through the lock cannot alter it. Total hold time < 1 µs per D-17.

### No runtime regression guard needed

Under Mutex, the "lock not held across commit" invariant is enforced by the type system — Mutex has no public manual `lock()`/`unlock()` methods, so holding the lock across commit is a compile-time impossibility. We do not insert any `precondition` or debug counter in `encode()`.

Compare with OSAllocatedUnfairLock: that type exposes `lock()` and `unlock()` as public methods, meaning programmer error could hold the lock across commit — and would need a `precondition(.notOwner)` assertion to catch it at runtime. Mutex makes that assertion structurally unnecessary.

### Per-frame MTLBuffer for Pass 2

```swift
var colorLocal = colorSnapshot  // mutable for `&colorLocal` address
guard let colorBuf = commandQueue.device.makeBuffer(
    bytes: &colorLocal,
    length: MemoryLayout<ColorUniform>.stride,
    options: .storageModeShared
) else {
    return  // allocation failure → drop this frame (consistent with texture-wrap failure handling)
}
pass2.setBuffer(colorBuf, offset: 0, index: 0)
// colorLocal & colorBuf can both go out of scope here.
// Metal retains colorBuf through the encoder/command-buffer lifetime.
// makeBuffer copied the bytes from &colorLocal, so the local var can be freed.
```

**Why this shape:**
- `makeBuffer(bytes:...)` **copies** — source lifetime irrelevant after it returns.
- `setBuffer` **retains** — the Swift `colorBuf` local can die.
- Matches brief §7 "memcpy'd into a per-frame MTLBuffer" literally.

### Stress-test writers-in-parallel + reader-in-parallel

```swift
// Reader: unstructured Task.detached so it runs concurrently with concurrentPerform,
// which synchronously blocks the calling thread. After concurrentPerform returns,
// await the reader's collected snapshots.
let reader = Task.detached(priority: .high) { () -> [UniformStorage] in
    var snaps = [UniformStorage]()
    snaps.reserveCapacity(10_000)
    for _ in 0..<10_000 { snaps.append(lock.withLock { $0 }) }
    return snaps
}

// Writers: brief-specified concurrentPerform. Synchronous.
DispatchQueue.concurrentPerform(iterations: 10_000) { i in
    lock.withLock { $0 = (i % 2 == 0) ? valueA : valueB }
    writeCount.wrappingIncrement(ordering: .relaxed)
}

let snaps = await reader.value
```

**Why this shape:**
- `concurrentPerform` is synchronous; can't await inside it.
- `Task.detached` runs the reader on a background thread so it overlaps with writers.
- `await reader.value` collects after writers finish.
- `Set<UniformStorage>` containment check catches torn reads — a byte-interleaved struct between `valueA` and `valueB` would not hash-equal either.

---

## 3. Gotchas

### 3.1 Lock never bridges `await`

`Mutex.withLock`'s closure body is synchronous by type — you cannot directly put `await` inside it. If you need to call an async function with the snapshot, structure as:

```swift
let snap = lock.withLock { $0 }          // synchronous — releases on closure return
await doAsyncThing(with: snap)            // outside the lock
```

Swift 6 strict concurrency catches violations at compile time. Mutex's noncopyable lock instance + `withLock`'s non-async signature combine to prevent even accidental await-across-lock patterns.

### 3.2 `nonisolated(unsafe)` — not needed in Stage 05

The swift-concurrency skill cautions against `nonisolated(unsafe)`. Stage 05 does not require it: Mutex handles all the cross-isolation synchronization, and no ad-hoc debug counters are needed (the invariant is type-enforced).

### 3.3 `@unchecked Sendable` for class types

Existing code uses `final class MetalPipeline: @unchecked Sendable` because it has mutable properties that are only written on one queue. Do NOT add new `@unchecked Sendable` types. The `UniformStorage` struct is auto-`Sendable` via its Sendable fields (`ColorUniform`, `CropUniform`, both value types with Sendable fields).

### 3.4 Sendable across the actor boundary

- `ProcessingParameters`: already `Sendable` ✓
- `ColorUniform`: becomes `Hashable` in Task 1 Step 2 — `Sendable` is synthesized because all fields are `Float`/`UInt32` ✓
- `CropUniform`: same ✓
- `UniformStorage`: `Sendable, Hashable` (Task 1 Step 1) ✓
- `ProcessingMetadata`: `Sendable, Hashable` (existing in `FrameSet.swift`, moved to its own file in Task 2) ✓

No `@Sendable` annotations needed on captures — the compiler synthesizes everything.

### 3.5 `MetalPipeline` does NOT currently retain `device`

The existing init signature `init(device: MTLDevice, ...)` receives the device but does not store it. We access it via `commandQueue.device` in the per-frame `makeBuffer` call — no new stored property needed, avoiding a diff on init.

Verified (from `MTLCommandQueue`): `var device: MTLDevice { get }` is the canonical accessor.

### 3.6 Pass 1 keeps `setBytes`

Brief §7 names only Pass 2 for the per-frame MTLBuffer. Pass 1's `setBytes` at `MetalPipeline.swift:244` remains unchanged. `cropSnapshot` is already taken under the lock on line 3 of `encode()`, so Inv 6 is satisfied for Pass 1 regardless of the MTL binding style.

### 3.7 Swift Testing is parallel by default

`@Test` functions run in parallel unless a `.serialized` trait is applied. Each test in Stage05Tests creates its own `Mutex` instance, so parallel execution is fine. If future tests share a fixture, use `@Suite(.serialized)` to serialize.

---

## 4. Concurrency boundary map (Stage 05 specifically)

```
@MainActor (slider UI)
   ↓ await setProcessingParameters(params)
CameraEngine actor
   ↓ synchronous inside actor
metalPipeline?.uniformsLock.withLock { $0.color = ColorUniform(params) }
   └─ lock held < 1 µs (struct field write)

AVCaptureVideoDataOutputSampleBufferDelegate delivery queue (ADR-02)
   ↓ captureOutput(_:didOutput:from:) callback
CaptureDelegate.onSampleBuffer?(sampleBuffer)
   ↓ closure (wired in CameraEngine)
MetalPipeline.encode(sampleBuffer:)
   ↓ first action
let snapshot = uniformsLock.withLock { $0 }  // lock held < 1 µs
   ↓ lock released — everything below runs lock-free
[Pass 1 setBytes, Pass 2 makeBuffer + setBuffer, gate check, commit]
```

**Lock is NEVER held across:**
- MTLCommandBuffer creation
- Encoder creation / configuration
- `setBytes` / `setBuffer` / `dispatchThreadgroups` / `endEncoding`
- `submissionGate.load(ordering: .acquiring)`
- `addCompletedHandler` registration
- `commandBuffer.commit()`
- Any `await`, `Task.detached`, or persistence dispatch

---

## 5. Brief / architecture deviations (documented decisions)

These choices deviate from either a skill, the literal brief text, or upstream architecture. Each is justified; all are logged in `state.md` at Task 9.

| # | Deviation | Justification |
|---|-----------|---------------|
| 1 | **`Mutex<UniformStorage>` (Synchronization framework, iOS 18+) instead of `OSAllocatedUnfairLock<UniformStorage>` per D-17** | **User-authorized override.** D-17 chose OSAllocatedUnfairLock when Mutex wasn't available. Mutex is the preferred Swift 6+ primitive per `all-ios-skills:swift-concurrency`; exposes only scoped `withLock`/`withLockIfAvailable` (no manual lock/unlock methods), so "held across commit" is structurally impossible — no runtime `precondition` needed. D-17 should be revised upstream. |
| 2 | `DispatchQueue.concurrentPerform` in stress test | Brief §8 explicitly names it. Swift-concurrency skill's "never GCD" rule is for production code; test harnesses with brief-specified shapes take precedence per CLAUDE.md §8. |
| 3 | Pass 1 keeps `setBytes` (no per-frame MTLBuffer) | Brief §7 names Pass 2 only for the per-frame MTLBuffer. Inv 6 is satisfied by the same lock-protected snapshot. |
| 4 | ProcessingMetadata missing `blackR/G/B` | Skeleton discrepancy carried from `implementation/architecture/api-skeletons/`. Stage 06 fixes; state.md tracks as Open Question. |
| 5 | FrameSet field stays `processing`, not `processingMetadata` | Brief §4 prose is imprecise (`processingMetadata` is the TYPE name, `processing` is the FIELD name). Api-skeleton authoritative; no rename needed. |
| 6 | `lock-not-held-across-commit` test does not add a runtime assertion | With Mutex, the invariant is enforced by the type system (no manual lock/unlock API exists). The test exercises the commit code path; no additional check is meaningful. Documented in the test's doc comment. |
| 7 | `CaptureDelegate.onProcessingMetadata` is a stub callback with no invocations in Stage 05 | Brief §4 asks for a hook; Stage 06 wires the consumer. The callback exists as a public property; no call sites populate it in Stage 05. |

---

## 6. File-by-file shopping list

For each file, exact lines / positions from the pre-Stage-05 baseline (as of 2026-04-21).

### `CameraKit/Sources/CameraKit/MetalPipeline.swift`

| Line(s) | Current content | Change |
|---------|-----------------|--------|
| 1–4 | imports | Add `import Synchronization` |
| 52–64 | scaffold doc + `UniformsHost` class | Delete entirely |
| 102–105 | scaffold comment + `let uniforms: UniformsHost` | Replace with `let uniformsLock: Mutex<UniformStorage>` + `lastProcessingMetadata` stub |
| 190 | `uniforms = UniformsHost(captureSize:)` | `uniformsLock = Mutex(UniformStorage.identity(captureSize:))` + `lastProcessingMetadata = nil` |
| 226–232 | scaffold snapshot | `let snapshot = uniformsLock.withLock { $0 }` + populate `lastProcessingMetadata` |
| 259–260 | Pass 2 `setBytes` | `guard let colorBuf = ... makeBuffer(...)` + `setBuffer(colorBuf, ...)` |
| 408 | `var color = uniforms.color` (in encodePass2Only test seam) | `var color = uniformsLock.withLock { $0.color }` |

**Not applicable for Stage 05 under Mutex:** inserting `precondition(.notOwner)` or a debug counter before `commit()`. Mutex's type-system guarantees make both unnecessary; the brief's "debug counter in the lock scope is zero at commit time" language predates Mutex and becomes moot.

Five scaffold marker sites removed: lines 54, 102, 226 (this file); 376, 381 (CameraEngine.swift, next row).

### `CameraKit/Sources/CameraKit/CameraEngine.swift`

| Line(s) | Current content | Change |
|---------|-----------------|--------|
| 376–379 | scaffold doc comment on `setProcessingParameters` | Delete |
| 381–382 | scaffold inline comment + `metalPipeline?.uniforms.color = ...` | `metalPipeline?.uniformsLock.withLock { $0.color = ColorUniform(params) }` |
| 407–412 | `pipeline.uniforms.crop = CropUniform(...)` | `pipeline.uniformsLock.withLock { $0.crop = CropUniform(...) }` |

### `CameraKit/Sources/CameraKit/FrameSet.swift`

| Line(s) | Current content | Change |
|---------|-----------------|--------|
| 68–81 | `public struct ProcessingMetadata { ... }` | Delete entirely (moves to its own file) |

All other lines unchanged. The `FrameSet.processing: ProcessingMetadata` field at line 15 stays; same-module resolution unaffected.

### `CameraKit/Sources/CameraKit/CaptureDelegate.swift`

Add one public property:

```swift
/// Stage 05 stub — Stage 06 wires this to the FrameSet publishing path.
/// Populated by CameraEngine after each MetalPipeline.encode() returns, using
/// `pipeline.lastProcessingMetadata`. No-op consumer in Stage 05 (nil by default).
var onProcessingMetadata: ((ProcessingMetadata) -> Void)?
```

One call-site wire in `CameraEngine` (the closure that sets `captureDelegate.onSampleBuffer`): after `metalPipeline?.encode(sampleBuffer:)`, add:
```swift
if let md = self?.metalPipeline?.lastProcessingMetadata {
    self?.captureDelegate?.onProcessingMetadata?(md)
}
```

Preserve the existing `[weak self]` capture pattern.

### `CameraKit/Tests/CameraKitTests/Stage04Tests.swift`

Two test functions touch `pipeline.uniforms.*`:
- `colorPipelineGoldenFrame` — writes `uniforms.color`, potentially reads it back
- `setCropRegionUpdatesUniform` — writes/reads `uniforms.crop`

Migration pattern (see plan Task 6 Step 2):
- `pipeline.uniforms.color = X` → `pipeline.uniformsLock.withLock { $0.color = X }`
- `pipeline.uniforms.crop = X` → `pipeline.uniformsLock.withLock { $0.crop = X }`
- `pipeline.uniforms.crop.originX` → `pipeline.uniformsLock.withLock { $0.crop.originX }` (or snapshot once)

### `CameraKit/Tests/CameraKitTests/Stage05Tests.swift`

New file. See plan Task 3 for full contents. Three `@Test` functions, all under `@Suite("Stage 05 — Uniform Lock + Per-Frame Snapshot")`.

### `CameraKit/state.md`

Plan Task 9 Step 2 specifies the updates. Key retire/add entries:
- Retire `04:unlocked-uniforms` (5 sites)
- Add permanent: `Mutex<UniformStorage>` (Synchronization framework, iOS 18+; override of D-17), `UniformStorage.swift`, `ProcessingMetadata.swift`, `lastProcessingMetadata` field, `onProcessingMetadata` stub
- Log the 7 deviations from §5 above under "Decisions taken that weren't in briefs" / "Open questions for next stage"

---

## 7. Verification commands

Run these at each checkpoint per the plan.

```bash
# Build
mcp__XcodeBuildMCP__build_device
# Fallback if MCP unavailable:
scripts/build-summary.sh

# Tests (pick filter per task)
mcp__XcodeBuildMCP__test_device                              # all
mcp__XcodeBuildMCP__test_device --filter Stage05Tests        # Stage 05 only
mcp__XcodeBuildMCP__test_device --filter "Stage0[1-5]Tests"  # all passing stages
# Fallback:
scripts/test-summary.sh --filter Stage05Tests

# Scaffold inventory
grep -rn '04:unlocked-uniforms' CameraKit/Sources/           # expect 0 hits after Task 5
grep -rn '01:simple-metal-passthrough' CameraKit/Sources/    # expect ≥1 (still alive)
grep -rn '01:skip-completion-guard' CameraKit/Sources/       # expect ≥1 (still alive)

# Scaffold table
scripts/scaffold-inventory.sh

# Final source cleanliness
grep -rn 'uniforms\.' CameraKit/Sources/                     # expect 0 hits (only uniformsLock remains)
grep -rn 'UniformsHost' CameraKit/Sources/                   # expect 0 hits (class deleted)

# Contracts regeneration (pre-commit hook handles this; manual if desired)
scripts/regen-contracts.sh
```

---

## 8. Red flags — stop and ask

If you encounter any of the following, **stop and raise the question** rather than patching:

1. **Compiler error "type `Mutex<UniformStorage>` has no member `lock`/`unlock`".** If you see this, someone tried to use manual lock/unlock — which Mutex does not expose. Use `withLock { ... }` instead. This is the invariant working as designed.
2. **Stage04Tests passing syntax doesn't compile after Task 6 migration.** Something about the old `pipeline.uniforms.crop.width` access pattern has changed semantics. Re-inspect the migration mapping.
3. **`scripts/scaffold-inventory.sh` reports 01:simple-metal-passthrough or 01:skip-completion-guard as missing.** These must remain alive until Stage 08/09. Any deletion during Task 4's MetalPipeline rewrite was accidental and must be restored.
4. **Swift 6 concurrency error about `@Sendable` captures inside `withLock`.** The captures must all be Sendable. If the diagnostic names a type you don't control, do not `@unchecked Sendable` around it — flag it.
5. **Pre-commit hook complains about `BeginDocumentationCommentWithOneLineSummary`.** Split multi-sentence doc comments: first sentence on `///`, blank `///` line, remaining sentences. swift-format `-i` does NOT fix this rule.
6. **`import Synchronization` fails or `Mutex` is not found.** Confirm deployment target is iOS 18+. Check `Package.swift` for the CameraKit target — platform clause must include `.iOS(.v18)` or later. iOS 26 (our actual target) is well above the minimum.

---

## 9. Further reading (optional; not required for execution)

- **`all-ios-skills:swift-concurrency`** — full skill text, including the `Mutex` vs `OSAllocatedUnfairLock` decision matrix and the "never GCD in production" rule we document-deviate from for tests.
- **`all-ios-skills:swift-testing`** — `@Suite`, parameterized tests, `#require` vs `#expect`, `.timeLimit`.
- **`implementation/ios-platform-guide/02-concurrency.md`** — ADR-07 (AVCaptureSession serial queue), ADR-09 (Metal submission gate), ADR-10 (Sendable strategy).
- **`implementation/architecture/02-concurrency.md#d-17-osallocatedunfairlock-for-host-written-uniform-buffer`** — authoritative lock-choice rationale.
- **Apple docs:** `https://developer.apple.com/documentation/os/osallocatedunfairlock` — the primary source for everything in §1.
