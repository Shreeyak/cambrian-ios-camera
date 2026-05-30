# 05 — Swift ↔ C++ Interop

Direct interop rules, exception discipline, reference-type import, and the async
consumer dispatch mechanism that sits on top.

---

## ADR-11: Direct Swift ↔ C++ interop; no Objective-C++

With Swift 6.2+ and `.interoperabilityMode(.Cxx)` plus `cxxLanguageStandard: .cxx20`,
the Clang module importer handles POD, `std::span`, and `enum class` cleanly. **Do
not add an Objective-C++ bridging layer.**

`.mm` files were the Swift 5-era workaround. They are unnecessary under Swift 6
C++ interop for the common cases. A project should contain zero `.mm` files.

### Rule: keep problematic headers out of Swift's view

Complex C++ headers (OpenCV, Eigen, anything with heavy templates, macros, or
exceptions in public headers) pain Swift's Clang importer. The fix is architectural:
**never let Swift import them.**

- **Public C++ headers** (exposed to Swift via the module map) contain only:
  - POD structs
  - `enum class` declarations
  - C-ABI callback typedefs (`using F = void (*)(void*, T)`)
  - `SWIFT_SHARED_REFERENCE`-annotated reference types
- **Private implementation** (`.cpp` files) may `#include` anything. Swift never
  sees these.
- In practice: one `Foo.hpp` in `include/` (Swift-safe), one `Foo.cpp` in `src/`
  (includes OpenCV, Eigen, etc.).

Build the C++ target as a pure-C++ SPM library target with no Apple-framework
dependencies in its public headers. This keeps it independently testable via
`swift test` on the macOS host without standing up a camera, Metal, or AVFoundation.

### Module map: what Swift sees (day-one setup, not a mitigation)

When exporting a Swift-visible `Cpp` module (or equivalent), the module map must
**not** `umbrella header "opencv2.h"` and must **not** textual-include the OpenCV
xcframework umbrella. This discipline is a day-one project setup item — it prevents
a category of unreviewable compile failures that are extremely hard to diagnose after
the fact.

Allowed `module.modulemap` shape:

```modulemap
module Cpp {
    umbrella header "CppPublic.h"    // POD + SHARED_REFERENCE types only; NO opencv2
    export *
}
```

`CppPublic.h` may include only:
- POD structs
- Plain classes with `SWIFT_SHARED_REFERENCE` annotations
- C-ABI function declarations (`extern "C"` blocks)
- **No `#include <opencv2/...>`** — not even in inline methods.

OpenCV headers are available only in source files that directly `#include` them
(`.cpp` translation units, non-exported private headers). Because those files are
not part of the Swift-visible module, Swift compilation never parses them.

**If this discipline is broken** — e.g. `opencv2.hpp` ends up transitively in a
Swift-visible header — Swift will attempt to parse thousands of OpenCV templates and
either produce a build failure or a wall of unreviewable compile errors. The failure
mode is disproportionate to the cause: one stray `#include` can make the entire
module unimportable with no actionable diagnostic.

---

## Importing C++ reference types: SWIFT_SHARED_REFERENCE

C++ classes with identity (own state, can't be copied) import as Swift reference
types via explicit retain/release function pairs:

```cpp
// Foo.hpp — public
class SWIFT_SHARED_REFERENCE(foo_retain, foo_release) Foo {
public:
    Foo();
    ~Foo();
    void doThing();
private:
    struct Impl;
    Impl* impl_;  // pimpl; OpenCV stays in Foo.cpp
};

extern "C" {
    void foo_retain(Foo* f);
    void foo_release(Foo* f);
}
```

Swift imports `Foo` as an ARC-managed class. No ObjC++ bridging, no
`@unchecked Sendable` raw-pointer wrappers.

Alternatives to avoid:

- **Importing as value type** (default) — wrong for classes with identity; causes
  copy of mutable state.
- **`@unchecked Sendable` Swift wrapper holding a raw pointer** — manual lifetime
  management, easy to leak or use-after-free.

---

## ADR-12: C++ exception discipline

**Every public C++ method is `noexcept`. Every internal call is wrapped in try/catch
at the facade. Exceptions are translated to error-code return values.**

Uncaught C++ exceptions crossing into Swift abort the process. Swift 6's C++ `throws`
importer is not yet production-ready for complex exception hierarchies (e.g.
`cv::Exception`).

Pattern:

```cpp
ErrorCode Foo::doThing() noexcept {
    try {
        impl_->doThing();
        return ErrorCode::Ok;
    } catch (const cv::Exception&) {
        return ErrorCode::OpenCVFailure;
    } catch (const std::exception&) {
        return ErrorCode::InternalFailure;
    } catch (...) {
        return ErrorCode::InternalFailure;
    }
}
```

The `noexcept` specifier asserts the contract in the type system. Enforce with a
"poison" test that feeds malformed input to every public method and asserts the
return is an `ErrorCode`, not a crash. Runs via `swift test` on host.

---

## std::span across the boundary

Prefer `std::span<T>` over raw pointer + length pairs for buffer arguments. Under
`.interoperabilityMode(.Cxx)`, `std::span` imports as Swift `Span<T>` without heap
allocation.

- Non-escapable: enforces "valid only for duration of this call" at the type level.
- Bounds-checked.
- No manual length-mismatch bugs.

The raw pointer + length pattern is still valid C; use `std::span` for new code.

---

## ADR-13: Async consumer dispatch (drop-on-busy)

Consumers of camera frames (anything downstream that might be slow — CV, ML, custom
analysis) are **always async**. Preview smoothness is inviolable — a slow consumer
must drop frames, not block the GPU pipeline. Synchronous dispatch inside the capture
delegate is not acceptable.

### Two viable mechanisms

**Mechanism A — C++ thread pool inside the imaging core.**

- Fixed-size thread pool (`std::min(4, std::thread::hardware_concurrency())`).
- Per-consumer 1-slot mailbox (newest frame overwrites pending; drop-on-busy).
- Consumers subscribe to a C++ `PixelSink` and run on pool threads.
- Best when: multiple consumers, may run in parallel, the imaging core is
  independently testable via `swift test`.

**Observability requirement for every `PixelSink` consumer (including tracker):**

Each `PixelSink` consumer MUST expose a `std::atomic<uint64_t> mailbox_overwrite_count`
that increments each time a new frame overwrites a pending one before the consumer
pulled it. The thread pool publishes all per-consumer overwrite counts to Swift via a
C-ABI metrics callback at the same cadence as the Swift-side `FrameDeliveryStats`
(ADR-19). Absence of this counter for any consumer — including `StreamId::Tracker` —
is a quality gate failure equivalent to a missing `dropped_mailbox_overwrite` on a
Swift-side lane. Silent drops are a correctness bug regardless of which mechanism
delivered them.

**Mechanism B — per-consumer `AsyncStream.bufferingNewest(1)` in Swift.**

- One stream per consumer; engine yields `sending Frame` on frame completion.
- Consumer `for await`s in a `Task` on its own queue / actor.
- Best when: one or two consumers, all-Swift product.

For multi-consumer products with a C++ analysis core, Mechanism A. For a single
Swift-side consumer, Mechanism B. Both satisfy drop-on-busy.

### 1-slot mailbox, not 4-frame queue

A 1-slot "newest wins" mailbox is preferred over a 4-frame bounded queue:

- Consumer always sees the newest frame, never stale.
- No accumulating latency under sustained overload.
- Simpler liveness guarantees.

A 4-frame queue is appropriate only when downstream needs sequential continuity
(e.g. optical flow requires frames in order) — not for the drop-tolerant case.

### What never crosses the consumer boundary

| Forbidden | Reason |
|---|---|
| Raw `CVPixelBuffer` into a consumer that retains past the callback | Capture session recycles the buffer |
| `MTLTexture` not backed by IOSurface | Metal texture identity isn't portable across command buffers |
| Anything non-Sendable on the return path | Crosses back to the engine and eventually `@MainActor` |

Consumer receives an IOSurface ref (retained for callback duration) and returns a
Sendable result struct. That's the entire contract.

### C-ABI callback pattern for C++ → Swift returns

C++ consumers return results to Swift via plain C function pointers, not via C++
std::function or virtual methods:

```cpp
// In the public C++ header
using EdgeResultCallback = void (*)(
    void* context,
    uint64_t presentationTimeNs,
    const uint8_t* edges,
    int32_t width,
    int32_t height,
    int32_t bytesPerRow
);

void setResultCallback(EdgeResultCallback cb, void* context);
```

Swift side:

```swift
// Retain the context box to keep `self` alive while the C++ pool holds the pointer
let box = Unmanaged.passRetained(self)
detector.setResultCallback({ ctx, pts, edges, w, h, stride in
    let engine = Unmanaged<CameraEngine>.fromOpaque(ctx!).takeUnretainedValue()
    // copy `edges` bytes to a Sendable Data here — buffer is valid only for this call
    let data = Data(bytes: edges!, count: Int(h) * Int(stride))
    Task { @MainActor in engine.viewModel.edgeResult = EdgeResult(...) }
}, box.toOpaque())
```

- C-ABI callbacks are trivially bridgeable; C++ virtual methods are not.
- `context: void*` is the opaque Swift self reference (`Unmanaged.toOpaque()`).
- Balance `passRetained` with a matching `release` or `takeRetainedValue` when the
  C++ side drops the callback (typically on unsubscribe).
- The buffer pointer is valid only for the duration of the callback. Copy what you
  need before returning.

### Keep `.interoperabilityMode(.Cxx)` contained

Enable C++ interop only on the Swift module(s) that actually touch C++ — typically
a thin "interop facade" module plus the C++ target. Every other Swift module should
be pure Swift (no C++ interop mode).

Reasons:

- C++ interop mode slows Swift compilation significantly (Clang module imports of
  C++ headers are slow).
- Pure-Swift modules get clean Sendable inference; interop modules need
  `@unchecked Sendable` on C++ wrappers and the analysis becomes manual.
- The facade is where you translate non-Sendable C++ return types into Sendable
  Swift result structs. Keeping the facade thin keeps that translation auditable.

### Back-pressure doesn't hop back

The engine never slows the camera hardware in response to a slow consumer. Drop-on-busy
absorbs the gap. If a consumer is consistently slow (e.g. Canny on full-resolution
instead of 480p), the fix is to change the input — downscale, strip channels — not
to introduce a backpressure mechanism.

---

## ADR-31: Swift-subclassing a C++ abstract class via `.interoperabilityMode(.Cxx)` is unproven; spike before design depends on it

The design may be tempted to express a consumer pattern like `PixelSink` as a C++
class with `virtual = 0` methods, then subclass it in Swift under direct interop. As
of Swift 6.2, Swift subclassing of C++ abstract classes works for some shapes and
fails for others — covariant returns, specific ABI alignments, and
override-across-module-boundaries have sharp edges. This path is not currently a
stable ABI guarantee.

Before any implementation phase's acceptance criteria depend on Swift-inheriting a
C++ abstract base, do a throwaway spike:

1. Define a C++ abstract class with one pure-virtual method using the exact shape the
   design needs.
2. Subclass it from Swift.
3. Instantiate the Swift subclass, hand the `PixelSink*` pointer to a C++ function
   that calls the virtual method, and verify the Swift override is dispatched
   correctly.
4. Run under TSan and debug+release builds.

If any step fails, fall back to a **C-ABI callback struct** — a POD `struct` of
function pointers plus an opaque `void* context`. The C++ side invokes the function
pointers; the Swift side registers a struct whose function pointers forward into a
Swift closure via the `Unmanaged.passRetained(context).toOpaque()` dance. This is
wire-level predictable and avoids the Swift/C++ v-table question entirely.

### C-ABI fallback shape

```cpp
// C-ABI fallback shape — predictable, no v-table question.
typedef struct {
    void (*onFrame)(void* context, const FrameData* frame);
    void (*onError)(void* context, int32_t code);
    void* context;
} PixelSinkCallbacks;

void pixel_sink_register(const PixelSinkCallbacks* cbs);
```

```swift
// Swift side
final class EdgeDetector {
    private var retainedSelf: Unmanaged<EdgeDetector>?
    func register() {
        self.retainedSelf = Unmanaged.passRetained(self)
        var cbs = PixelSinkCallbacks(
            onFrame: { ctx, frame in
                let d = Unmanaged<EdgeDetector>.fromOpaque(ctx!).takeUnretainedValue()
                d.handle(frame!.pointee)
            },
            onError: { ctx, code in /* ... */ },
            context: self.retainedSelf!.toOpaque()
        )
        pixel_sink_register(&cbs)
    }
}
```

Cross-references: ADR-11 (direct interop module-map discipline), ADR-13 (async
consumers / 1-slot mailbox; includes the C-ABI callback pattern for C++ → Swift
returns), G-27 (`@unchecked Sendable` silences the diagnostic but not the race —
applies to the `context: void*` pointer retained via `Unmanaged`).

---

## ADR-18: Frame set publication (`FrameSet`)

ADR-13 specifies *that* consumers are async and drop-on-busy. This ADR specifies
*what* gets published and *how it's correlated* across all three output sinks.

### Decision

Consumer lane mailboxes carry a `FrameSet` — one atomic unit containing three
**IOSurface-backed** pixel-buffer refs, full capture metadata, processing metadata,
and derived tracker signals, covering all three consumer sinks defined by the product.

```swift
struct FrameSet: Sendable {
    let frameNumber: UInt64         // monotonically increasing; resets to 0 on engine open()
    let captureTime: CMTime         // presentation timestamp from CMSampleBuffer

    // IOSurface-backed CVPixelBuffers from their respective pools (see ADR-19).
    // Each buffer has kCVPixelBufferIOSurfacePropertiesKey set at pool creation.
    // Zero-copy: the same IOSurface the GPU wrote is what the consumer reads.
    let natural:   CVPixelBuffer    // full-res RGBA16F; crop only, no color ops
    let processed: CVPixelBuffer    // full-res RGBA16F; crop + color ops
    let tracker:   CVPixelBuffer    // RGBA16F; downsampled from processedTex,
                                    // aspect ratio preserved (target height ~480p,
                                    // width = processedTex.width × 480 / processedTex.height)

    let capture: CaptureMetadata        // camera hardware settings at capture time
    let processing: ProcessingMetadata  // Metal pipeline parameters applied to this frame

    // Tracker signals computed in Pass 4 — attached for zero-ambiguity frame correlation
    let blurScore: Float
    let trackerQuality: TrackerQuality
}

/// Camera hardware settings active when this frame was captured.
struct CaptureMetadata: Sendable {
    let iso: Float
    let exposureDuration: CMTime
    let whiteBalanceGains: WhiteBalanceGains  // hardware gains from AVCaptureDevice
    let whiteBalanceMode: WhiteBalanceMode    // .auto / .manual / .locked
    let lensPosition: Float                   // 0.0–1.0 normalized
    let focusMode: FocusMode                  // .auto / .manual / .locked
    let exposureMode: ExposureMode            // .auto / .manual / .locked
    let zoomFactor: CGFloat
    let cameraPosition: CameraPosition        // .front / .back / .wide
}

/// Post-processing parameters applied in the Metal pipeline for this frame.
struct ProcessingMetadata: Sendable {
    let cropRect: CGRect        // in sensor pixel coordinates
    let brightness: Float       // applied in Pass 2
    let contrast: Float
    let saturation: Float
    let gamma: Float
    let whiteBalanceGains: WhiteBalanceGains  // gains applied in the Metal shader
                                              // (may differ from hardware gains)
}

// Plain Sendable wrapper — AVCaptureDevice.WhiteBalanceGains is ObjC-imported
// and not guaranteed Sendable in Swift 6.
struct WhiteBalanceGains: Sendable { let red: Float; let green: Float; let blue: Float }
```

**`FrameSet` is a handoff of IOSurface refs, not a copy of pixels.** The
`CVPixelBuffer` is the Apple-level handle; the `IOSurface` beneath it is the
cross-process, cross-API GPU memory that VideoToolbox, Metal, and C++ consumers
can all map without copying. A C++ consumer retrieves the underlying surface via
`CVPixelBufferGetIOSurface(set.processed)` and holds it for the duration of
processing; ARC on the `CVPixelBuffer` keeps the surface alive across the hop.

### Three named sinks

The product has three distinct output lanes from the Metal pipeline, each
supporting N consumers:

| Field | Content | Pool |
|---|---|---|
| `natural` | Full-res RGBA16F; crop only, no color ops | natural pool |
| `processed` | Full-res RGBA16F; crop + color ops | processed pool |
| `tracker` | RGBA16F; downsampled from processedTex, aspect ratio preserved | tracker pool |

The natural MTKView preview and the processed MTKView preview draw from the same
IOSurfaces as the consumer lanes — written in the same command buffer pass —
so display and async consumers are always bit-identical.

### Why one atomic unit, not three independent streams

All three buffer refs originate from the same Metal command buffer. If they lived
in separate mailboxes, a consumer correlating natural + processed frames could
observe inconsistent sets (natural of frame N alongside processed of frame N-1)
because mailbox updates race. Publishing as a single atomic unit makes cross-sink
correlation impossible to miswire. A consumer that only needs tracker ignores the
other fields; the marginal cost of always computing all three passes is negligible.

### Publication rules

- All three `CVPixelBuffer`s are pre-dequeued from their respective pools *before*
  the Metal compute passes run, so all refs are in scope at commit time.
- The completion handler (still on the delivery queue) constructs the `FrameSet`
  and performs an atomic swap into each subscribed lane's mailbox. The swap
  releases the prior set, which releases the underlying `CVPixelBuffer`s when
  the consumer no longer holds them.
- `frameNumber` and `captureTime` let the consumer correlate to external streams
  (IMU, sensor metadata) without depending on clock alignment.

### Non-goals

- **Per-lane shape variation.** Every lane receives the full set. Consumers that
  don't need all three buffers ignore the unused fields.
- **Set depth > 1.** See ADR-19; all lanes are latest-wins.

---

## ADR-19: Pool sizing, latest-wins mailboxes, observability

ADR-18 defines the unit of publication. This ADR defines the pool backing the
`CVPixelBuffer` refs inside that unit, the mailbox policy, and the drop
accounting.

### Pool configuration

Three `CVPixelBufferPool`s — one per frame type (`natural`, `processed`, `tracker`).
All IOSurface-backed and Metal-compatible. Same attributes for each:

```swift
let poolAttrs: [String: Any] = [
    kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
    kCVPixelBufferPoolMaximumBufferAgeKey   as String: 1.0,   // seconds
]
```

- Minimum 3 covers the common 0–1 active-consumer case (1 current mailbox ref
  + 1 GPU write slot + 1 slack).
- CF grows each pool on demand past this minimum and ages buffers out after 1s
  of disuse. **No explicit grow/shrink code** — trust CF.

### Cap formula

```
pool cap = N_active_lanes + 1
```

The `+1` is always-empty — the GPU write slot, so writes never stall waiting for
a consumer to release a ref (stalling violates preview-inviolable, ADR-13). Each
latest-wins consumer holds ≤ 1 buffer ref during processing; that's the N term.

The formula is documentation; CF handles allocation at runtime. Use it when
debugging "pool size keeps growing" symptoms to check whether a consumer is
leaking refs.

### Mailbox semantics

- Per-lane 1-slot atomic holding the latest `FrameSet`.
- On publish, the prior set (if any) is released. If the prior set was never
  pulled by the consumer, increment `dropped_mailbox_overwrite` for that lane.
- Consumer pulls: retain the set (all three `CVPixelBuffer` refs become consumer-held),
  process on the consumer's own queue, release when done. CF reclaims buffers
  whose refcount drops to 1 (pool only).

**All-frames-bounded is not supported for this project.** Every lane is
latest-wins. If a future consumer needs all-frames semantics (e.g. an
IMU-correlated stitcher that can't skip), revisit — don't layer it on as an
option, because mixing policies in one pool makes cap sizing non-local.

### Pool exhaustion

Should not occur under `N + 1` sizing with latest-wins semantics. If
`CVPixelBufferPoolCreatePixelBuffer` returns
`kCVReturnWouldExceedAllocationThreshold`:

- GPU drops the frame (no commit that cycle).
- Increment global `pool_exhaustion` counter.
- Log a warning identifying the lane with the oldest outstanding ref — the
  primary suspect for the jam (a consumer holding a ref longer than its frame
  budget).

### Dynamic subscription

```swift
// Consumer side
let stream = engine.subscribe()   // AsyncStream<FrameSet>
for await set in stream {
    // process; release at end of loop iteration
}

// Unsubscribe by terminating the Task that owns the for-await loop.
```

- `subscribe()` allocates a new lane + mailbox atomically.
- Pool grows on the next frame that needs a fresh buffer; CF handles this.
- Unsubscribe releases the lane; CF ages out the unused buffer after 1s.

### Observability

Per-lane counters:

| Counter | Increments on |
|---|---|
| `frames_produced` | GPU commit published a pair to this lane |
| `frames_delivered` | consumer pulled the pair |
| `dropped_mailbox_overwrite` | new pair replaced an unpulled prior pair |
| `hold_over_budget` | consumer held a pair > N frame intervals (default 3) |

Global counters:

| Counter | Meaning |
|---|---|
| `pool_exhaustion` | pool dequeue returned `kCVReturnWouldExceedAllocationThreshold` |
| `pool_current_size[pool]` | CF-managed buffer count per pool (diagnostic) |

Surfaced to the view model via a separate `AsyncStream<FrameDeliveryStats>`.
For analyzer apps, `frames_produced != frames_delivered` is a visible error
state — surfaced in debug UI, not hidden. Silent drops are a correctness bug.

**C++ PixelSink consumers (Mechanism A) must appear in the same `FrameDeliveryStats`.**
The per-consumer `mailbox_overwrite_count` from each C++ `PixelSink` (including
`StreamId::Tracker`) is published via a C-ABI metrics callback and folded into
`FrameDeliveryStats` alongside the Swift-side per-lane counters. The absence of a
tracker-lane overwrite counter in `FrameDeliveryStats` is a quality gate failure —
a pool exhaustion counter exists for the recorder; the same discipline is required
for every PixelSink consumer.
