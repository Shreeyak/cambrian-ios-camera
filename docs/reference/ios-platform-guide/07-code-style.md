# 07 — Code Style

Swift style baseline the implementation agent follows. Two ADRs, both compact.
Read this once; cite by ID thereafter.

---

## ADR-24: Naming, golden-path, self-omission, trailing-closure rules

The whole Swift style contract for this app, in five rules. Any deviation belongs
in a `D-##` decision entry, not in the code.

### Naming

- `UpperCamelCase` — types, protocols.
- `lowerCamelCase` — everything else (methods, vars, enum cases, parameters).
- **Clarity > brevity.** Spell names out: `configuration`, not `cfg`; `manager`,
  not `mgr`; `context`, not `ctx`. The only accepted abbreviations are `URL`,
  `ID`, `UUID`.
- No "kitchen-sink" generic names. `CameraEngine`, `ConsumerRegistry`,
  `TexturePoolManager` — not `CameraManager`, `FrameHandler`, `Helper`.
- Methods read as English phrases at the call site: `startRunning()`,
  `fetchFrame(ofType:)`, `pauseIfNeeded()`.

### Golden path (guard-first, no nested `if`)

Happy path stays at the left margin. Error cases exit with `guard … else`.

```swift
// ✅ Preferred
func open() async throws {
    guard state == .idle else { throw EngineError.alreadyOpen }
    guard await requestCameraAccess() else { throw EngineError.cameraDenied }
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                               for: .video, position: .back)
    else { throw EngineError.noBackCamera }

    try configure(device)
    session.startRunning()
    state = .streaming
}
```

Nested `if` / `else` trees deeper than one level are a review failure.

### `self` omission

Omit `self` unless the compiler requires it (escaping closures, disambiguation).
Mixing `self.` and bare names within one type scans worse than either discipline
on its own. Pick "omit" and keep it.

```swift
// ✅
func configure() {
    backgroundColor = .systemBackground  // no `self.`
    session.addInput(input)
}

// ✅ closure — compiler-required
consumer.onDelivery { [weak self] frame in
    guard let self else { return }
    self.handle(frame)
}
```

### Trailing closure — single parameter only

Trailing-closure syntax is used **only** when there is exactly one closure
argument. Multi-closure calls use labeled arguments in parentheses — the call
site is more readable and less ambiguous at edit time.

```swift
// ✅ single closure — trailing is fine
session.async {
    session.startRunning()
}

// ✅ multi-closure — labels, no trailing
AsyncImage(url: url) { phase in
    // …
} placeholder: {
    ProgressView()
}

// ❌ avoid — bare trailing on a multi-closure call
UIView.animate(withDuration: 0.3) {
    view.alpha = 1
} completion: { _ in }     // acceptable if one trailing is the common case,
                           // but prefer explicit labels when reading matters
```

### Type annotation on empty collections

```swift
var names: [String] = []          // ✅
var counts: [String: Int] = [:]   // ✅
var names = [String]()            // ❌ noisier; compiler infers [String]
```

Non-empty literals — let the compiler infer.

---

## ADR-25: Error type discipline

Every throwable public API in this app throws a **named enum: Error** defined in
the owning module. Untyped `throws` is permitted internally; at module boundaries
the error type is precise.

### Why

- The `CameraEngine` public surface (`open`, `close`, `setResolution`,
  `capturePhoto`, `startRecording`) is consumed by SwiftUI code and by test
  harnesses. Typed errors let the call site exhaustively switch.
- `NSError` and string-typed errors (`throw MyError("oops")`) defeat the pattern.
- Swift 6's `throws(SomeError)` (typed throws, SE-0413) makes this compile-time
  enforceable where appropriate — use it at module boundaries. Internal
  throwing functions may still use untyped `throws` when a shared error type
  would force artificial unification.

### Baseline error enums

Each module declares at least one. Example for the engine module:

```swift
public enum EngineError: Error, Sendable {
    case alreadyOpen
    case notOpen
    case cameraDenied
    case noBackCamera
    case lockForConfigurationFailed(underlying: Error)
    case unsupportedFormat(reason: String)
    case metal(MetalError)
    case interop(InteropError)
}

public enum MetalError: Error, Sendable {
    case commandBufferFailed(MTLCommandBufferError)
    case textureCacheExhausted
    case pipelineStateCompilation(String)
}
```

### Rules

1. Every enum case that wraps an external error (Apple framework, C++) stores
   the original via `underlying: Error` (or a domain-specific wrapped type) so
   root cause is never lost.
2. Error enums are `Sendable` — crossed actor boundaries routinely.
3. `throw MyError("string")`-style anonymous errors are banned. If a case does
   not warrant its own enum case, it warrants a single shared `.generic(String)`
   case scoped to the module (and even that is a last resort).
4. `fatalError` is reserved for programmer errors that prove an invariant has
   already been violated (e.g. "compiled pipeline state should never be nil
   here"). Never used for recoverable conditions.

### At the SwiftUI boundary

`ViewModel` exposes `@Observable` `currentError: EngineError?` for the view to
present. The view does not catch `Error` — it reads the typed state.

---

---

## ADR-33: Testing strategy: Swift Testing for unit, XCTest for integration, `CaptureDeviceProviding` as the seam

**Unit tests (Swift Testing):** all pure-logic components — state machine, error
classifier, recovery backoff, settings merge, EXIF JSON schema, color-format
channel-order validation — are tested with Swift Testing (`@Test` / `#expect`). No
real AVFoundation. No real Metal device. The fake `CaptureDeviceProviding` (ADR-32)
is the seam; tests never construct `AVCaptureDevice`.

**Integration tests (XCTest):** any test that needs a real Metal device, a real
AVFoundation pipeline, or the real OpenCV consumer runs under XCTest on the simulator
or on a device lab. Golden-frame tests (render a known input through the real Metal
pipeline, compare output against a checked-in reference with a tolerance threshold)
are XCTest. Tests that boot the real `AVCaptureSession` and verify a session
transition observed in state are XCTest.

**Golden-frame corpus:** reference images are checked in under `Tests/GoldenFrames/`.
Each test loads an input tile + expected output tile; comparison uses per-pixel Lab ΔE
tolerance (ΔE < 2 typical). Failures write the actual output and a diff visualization
alongside the reference for inspection.

**Acceptance rule:** every deliverable from Phase 1a onward ships with unit tests at
the `CaptureDeviceProviding` seam. If a component under test requires AVFoundation or
Metal to exercise its logic, it needs refactoring against ADR-32, not a pass on unit
testing.

Cross-references: ADR-24 (Swift style), ADR-25 (error type discipline), ADR-32
(`CaptureDeviceProviding`).

---

## Style rules *not* in this document

- File layout per-module (where `CameraEngine.swift` lives, what's in
  `Sources/`) belongs in `design/` output, not here.
- Comment density / doc-comment conventions are covered by the root `CLAUDE.md`:
  "default to writing no comments … explain WHY, not WHAT."
