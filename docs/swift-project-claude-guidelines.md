# Swift / SwiftUI / C++ Project Guidelines

CLAUDE.md template for Swift 6 + SwiftUI + C++ direct interop projects. Derived from cambrian/camera2_flutter_demo learnings.

---

## Quick Start

```bash
swift build                          # Build the package
swift test                           # Run all tests
xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme MyApp test -destination 'platform=iOS Simulator,name=iPhone 16'
```

> Fill in project-specific targets, schemes, and device names. Never use `-configuration Release` for verification builds; debug builds are sufficient and avoid signing complications.

---

## Project Structure

> Fill in the directory layout for this project before use.

---

## Living Documents

Read these before making changes to internals:

- **`docs/architecture.md`** — component relationships, data flow, C++/Swift boundary. **Read before modifying any Swift or C++ file.**
- **`docs/usage-guide.md`** — public API and usage patterns. **Read before modifying public-facing APIs.**

When making changes, update docs as follows:

1. Update the `///` docstring / KDoc on every changed symbol.
2. Search for any doc that *references* the changed symbol and update those too.
3. Update `docs/usage-guide.md` if any public Swift API changed.
4. Update `docs/architecture.md` if data flow or component relationships changed.
5. Verify all code samples in docs compile against the current API.

---

## Codegen Wrapper Scripts

If this project has any codegen step (Swift macros, C++ binding generators, protobuf, etc.), **always use the wrapper script** — never the raw tool directly. Wrapper scripts apply post-patches and validate output. Document the script location here.

---

## Threading Model

This project follows a strict two-context threading model, analogous to a background-worker / main-thread split:

- **Background queue / actor** — all AVFoundation, Camera, and C++ operations (open, configure, capture, teardown, Metal command encoding). Any code that touches hardware state, native handles, or pipeline state must run here.
- **`@MainActor` / `DispatchQueue.main`** — all SwiftUI/UIKit updates and delegate callbacks to callers.

**Pattern for new public methods:**

```swift
func myMethod() async throws {
    // Dispatch camera/C++ work off the main actor
    try await cameraQueue.run {
        // ... AVFoundation / C++ work ...
    }
    // UI update is safe here if the function is @MainActor, or:
    await MainActor.run { /* update @Published / @State */ }
}
```

**Swift 6 strict concurrency rules:**

- Camera state belongs to a non-`@MainActor` actor or an isolated serial `DispatchQueue`; never mutate it from `@MainActor` directly.
- `Sendable` conformance is required for all types that cross actor or task boundaries. C++ types bridged via direct interop are **not** automatically `Sendable` — add explicit conformance only after verifying thread safety.
- `DispatchQueue.sync` from a queue onto itself deadlocks. Never do it. Use `async` or restructure ownership.
- `deinit` and teardown methods that call `queue.sync` will deadlock if a callback executing on that queue is still in-flight. Use dispatch group drain or actor re-entrancy patterns.

**Captured vs field references in closures:**

```swift
// BAD — uses self.pipelineHandle (field) inside the closure; may be nil after stop()
func rebindSurface(_ layer: CALayer) {
    let handle = pipelineHandle   // captured for nil guard
    guard handle != nil else { return }
    cameraQueue.async {
        nativeRebind(self.pipelineHandle, layer)  // BUG: field may be cleared
    }
}

// GOOD — closure uses the captured snapshot
func rebindSurface(_ layer: CALayer) {
    guard let handle = pipelineHandle else { return }
    cameraQueue.async {
        nativeRebind(handle, layer)
    }
}
```

Any native handle or shared resource referenced inside `DispatchQueue.async`, `Task {}`, or actor-isolated closures **must** use a locally captured value, never the class field.

---

## C++ Interop Rules

### Parameter Tracing

When adding or changing a parameter, trace the **full call chain** — every layer must be updated or the mismatch causes silent data corruption:

```
Swift API  →  @_expose(Cxx) / Obj-C bridge (if any)  →  C++ function  →  C++ struct / uniform
```

1. Update every layer: Swift signature, bridging header (if present), C++ function, C++ struct fields and any callers.
2. If semantics change (identity value, range, units), update tests, docs, header comments, and validation.
3. For positional C function arguments, verify argument order matches at both the Swift call site and the C++ implementation.

### Type Mapping at the Bridge

| Swift | C++ |
|---|---|
| `Float` | `float` |
| `Double` | `double` |
| `Int` | `ptrdiff_t` / `ssize_t` (platform-wide) |
| `Int32` | `int32_t` |
| `Int64` | `int64_t` |
| `Bool` | `bool` |

Assign explicit casts at the boundary. `Int` vs `Int32` is a common source of silent truncation on 64-bit platforms.

### Sendable and Lifetime

- C++ types imported into Swift are not `Sendable` by default. Do not pass them across actor boundaries without explicit synchronization.
- C++ objects with raw pointer ownership called from Swift need explicit release in all Swift error paths (throw, guard-return, early return). Prefer C++ smart pointers (`std::unique_ptr`, `std::shared_ptr`) to eliminate manual cleanup.
- Resources acquired before an `await` in an `async throws` function need cleanup if the continuation throws.

### Header Hygiene

Every C++ header must include everything it directly uses. `std::string`, `std::vector`, `std::optional` all need explicit `#include` directives. Do not rely on transitive includes.

---

## Rules for AI Agents

- **Always read error logs first.** When debugging frame delivery, GPU, or camera failures, read the Xcode console / `os_log` / `NSLog` output IMMEDIATELY before proposing hypotheses. Logs are the primary diagnostic tool. Do not skip this even for "obvious" issues.
- **Never leave TODOs for required behavior.** If a plan says to call an API and you can't find it, search broadly (`grep -r` across the source tree). Only report NEEDS_CONTEXT after exhaustive search. Do not comment out calls or stub them.
- **Match surrounding patterns.** Find 2–3 similar functions and match their threading, error handling, and state notification patterns. Code samples in plans are sketches — the codebase is the source of truth for HOW to implement.
- **State notifications are mandatory.** Any path that changes camera, recording, or error state MUST notify the UI layer via `@MainActor` / `@Published` / delegate callbacks.
- **Verify before claiming "doesn't exist."** Fields may be far from your edit site in a large file.
- **Name magic numbers and explain why.** Save any non-trivial literal to a descriptive named constant. Add a comment answering "why this value and not another." Applies to thresholds, timing values, dimensions, and scaling factors. Self-evident values (`0`, `1.0` in a clamp) are exempt.
- **Write docstrings for new public APIs and classes.** Every new `public` method, class, struct, enum, and typealias needs a `///` Swift doc comment. Private helpers only need docs when the purpose isn't obvious from the name. C++ public API needs Doxygen-style comments.
- **Async callbacks must resolve on all paths.** Every `async throws` function and completion handler must resolve (return, throw, or call its completion) on success, failure, AND early return. Use `defer` to ensure cleanup and resolution. A missing `throw` or early return silently hangs the `await` site.
- **Trace parameters through all layers.** When adding or changing a parameter, follow the full chain: Swift API → bridging layer → C++ function → C++ struct. Missing a layer causes silent data corruption. Applies to renames, type changes, and removals.
- **Trust the log's verdict line, not the process exit code.** "Exit code 0" can lie. Always read the build log's own verdict (`** TEST SUCCEEDED/FAILED **`, `BUILD SUCCEEDED`, `All tests passed!`) — not just the shell exit code.

---

## Code Review Patterns — Critical (Tier 1)

These are the patterns most likely to cause crashes, data corruption, or deadlocks. Check on every change.

### 1. Thread Safety: Captured vs Field References in Closures

See the **Threading Model** section above. The rule in one line: any native handle or mutable shared resource used inside a dispatched closure must be a locally captured value, not the class field.

**Self-join deadlock:** never call `queue.sync` from within that queue's own closure, and never destroy or join a queue-owning object from within that queue's callback.

**Shared mutable state:** if C++ state is accessed from multiple threads (e.g., a processing callback racing with teardown), protect every access site with the same `NSLock`, `os_unfair_lock`, or actor boundary — including the teardown path that zeros the pointer.

### 2. Failure Paths Must Always Resolve

Every `async throws` function, completion handler, and delegate must resolve on all paths — success, failure, and early return:

1. On failure, `throw` or call `completion(.failure(...))` before returning.
2. Never force-unwrap (`!`) after a fallible operation; use `guard let` and fail gracefully.
3. State reported to the UI must reflect actual runtime state, not the requested configuration.
4. If a resource is registered (e.g., added to a dictionary) before an async call, remove it in the failure path.
5. Use `defer` for cleanup that must happen on every exit path.

### 3. Parameter Contract Misalignment Across Layers

When adding or changing a parameter:

1. Trace the full call chain (see **C++ Interop Rules — Parameter Tracing**).
2. If parameter semantics change (identity value, units, range), update all tests, docs, header comments, and validation logic.
3. Never assume two data planes share the same stride or format — pass separate values or add a validated assertion.

### 4. Metal/GPU State on the Right Queue

All Metal command buffer encoding/submission must happen on the correct `MTLCommandQueue`-owning context. `MTLBuffer`, `MTLTexture`, and `MTLRenderPipelineState` are not thread-safe by default — do not access them from multiple threads without explicit synchronization.

Methods that create, destroy, or bind Metal render targets must run on the rendering queue (equivalent of the GL thread rule). New methods touching `MTLTexture` handles or render pipeline state must follow the same dispatch pattern as existing render methods.

Return values from Metal operations that can fail must be checked. If a drawable or command buffer becomes invalid, log and skip the dependent operations rather than proceeding blindly.

### 5. Race Conditions in Async / Camera Flows

- Use `AVCaptureVideoDataOutputSampleBufferDelegate` or `AsyncStream` for async frame/image results — never poll immediately after dispatching an async capture operation.
- Concurrent calls that overwrite a shared completion handler orphan the first callback. Serialize with an in-flight guard or a task queue.
- In-flight guards must be cleared in `defer` blocks, not just happy-path continuations.
- Register observers/delegates **before** the operation that may trigger them.
- Don't wrap an error handler around a function that already handles its own errors — it double-counts retries and can queue overlapping re-open attempts.

---

## Code Review Patterns — Major (Tiers 2–3)

### 6. Documentation Drift

The most frequent issue by raw count — appeared in every reviewed PR. Enforce the 5-point checklist from **Living Documents** on every change. Additional rules:

- Use precise terminology (e.g., "pre-shader passthrough" not "sensor raw").
- Never document APIs that aren't implemented yet — mark them `// Planned` or omit them until they ship.
- Code samples in docs must compile against the current API.

### 7. Codegen Not Regenerated After API Changes

If this project uses any codegen (Swift macros, protobuf, C++ binding generators), regenerate **immediately** after changing the source schema. Verify that the generated output matches the new schema on both sides of the boundary.

### 8. Incomplete Resource Cleanup on Failure Paths

Use `defer` for multi-resource acquisition in Swift. C++ RAII (`std::unique_ptr`, `std::shared_ptr`) handles cleanup if used; raw pointers called from Swift need explicit release in all Swift error paths (throw, guard-return, early return).

Do not release C++-side resources while a background thread or callback may still be using them. Drain or cancel in-flight work before releasing shared objects.

### 9. Tests Not Updated After Signature or Semantic Changes

After changing any function signature, `grep` for all call sites including tests. After changing default values or valid ranges, search for the old values in test assertions. Run `swift test` / `xcodebuild test` before pushing.

### 10. Missing Input Validation and Edge-Case Guards

- Use `precondition`, `assert`, or `throw` in constructors for invariants (e.g., `precondition(stops.count >= 2)`).
- Guard division and formatting against zero/negative/infinite inputs.
- Use `isFinite` not `isNaN` when you need to reject both NaN and infinity.
- Default values must be within the valid ranges they will be used with.
- Initialize all `std::function` / closure members in C++ with a no-op default to avoid `std::bad_function_call`.

### 11. Optimistic UI State Without Backend Confirmation

Don't flip `@State`, `@Published`, or `@Observable` properties before the backend confirms the transition. Await confirmation (or revert on rejection) before updating observable state. Compare actual field values for equality checks — `class` instances with `===` will always differ from a `copyWith`-style replacement even when contents are identical; use `Equatable` on your state types.

### 12. Breaking Public API Changes Without Deprecation

When renaming or removing a public Swift symbol:

1. Keep the old name with `@available(*, deprecated, renamed: "newName")`.
2. Remove the deprecated alias only in a major version bump.

### 13. State Not Persisted Across Pipeline Recreation

Cache the last-applied configuration in a Swift property. After creating or recreating the native pipeline (e.g., after a camera error or `AVCaptureSession` interruption), replay the cached state immediately.

---

## Code Review Patterns — Medium / Minor (Tiers 4–5)

### 14. Type Mismatches at the Swift/C++ Bridge

`Float` vs `Double` and `Int` vs `Int32` vs `Int64` vs C++ `int` are common sources of silent truncation or precision loss. Add explicit casts at every bridge crossing. See the type mapping table in **C++ Interop Rules**.

### 15. Hardcoded Layout Assumptions in SwiftUI

Use `GeometryReader` or `containerRelativeFrame` for actual dimensions. Don't hardcode constants that duplicate a `.frame()` modifier — they drift. Never fabricate hardware capability values — disable the UI control for unsupported hardware instead.

### 16. Brittle Wire Formats Across the Swift/C++ Bridge

Don't parse structured data out of strings across the Swift/C++ bridge. Use proper Swift structs with `@_expose(Cxx)` or pass typed C++ structs. If a function returns more than one value, define a named struct — not a tuple encoded in a string.

### 17. Unnecessary Work When No Consumers Are Attached

Check whether any observers/subscribers exist **before** allocating frame buffers or doing expensive copy/encode work.

### 18. Machine-Specific Paths in Committed Files

Do not commit absolute paths to `.clangd`, `.xcconfig`, build scripts, or any other tracked file. Use relative paths, env variables, or `$(SRCROOT)`-relative Xcode build settings.

### 19. Missing C++ Header Includes

Every C++ header must include everything it directly uses. `std::string`, `std::vector`, `std::optional` all need explicit `#include` directives. Do not rely on transitive includes.

### 20. Undocumented Platform Restrictions

Document any `@available` annotations, minimum iOS/macOS targets, and ABI requirements with rationale (e.g., why `arm64` only). Provide a clear error or compile-time diagnostic for unsupported configurations.

---

## Pre-PR Checklist

**Critical — block merge if violated:**

- [ ] All dispatched closures (`DispatchQueue.async`, `Task {}`, actor hops) use captured local variables, not class fields, for native handles
- [ ] No `queue.sync` from within that queue's own callback (self-join deadlock)
- [ ] No teardown/deinit that joins a queue while a callback on that queue is in-flight
- [ ] Every `async throws` function and completion handler resolves on all code paths (success, failure, early return)
- [ ] No force-unwrap (`!`) after fallible operations
- [ ] New/changed parameters traced through all layers: Swift → bridge → C++ function → C++ struct
- [ ] All Metal/GPU resource access marshalled to the correct rendering context
- [ ] Metal operations that can fail have return values checked
- [ ] Async results use delegates/`AsyncStream`, not immediate polling
- [ ] In-flight guards cleared in `defer` blocks, not just happy-path continuations
- [ ] Observers/delegates registered *before* the operation that may trigger them

**Major — fix before PR approval:**

- [ ] `///` docstrings match current function signatures and data flow
- [ ] Code samples in docs compile against the current API
- [ ] Docs don't describe unimplemented APIs as available
- [ ] Codegen re-run after schema changes; generated output verified on both sides
- [ ] Failure paths clean up every acquired resource (Swift `defer` + C++ RAII)
- [ ] Tests updated for any signature or semantic changes (grep for old call sites)
- [ ] `swift test` / `xcodebuild test` passes
- [ ] Constructor invariants enforced with `precondition`/`assert`/`throw`
- [ ] Default values are within valid ranges
- [ ] State cached and replayed after pipeline recreation

**Medium — fix in same PR if the area was touched:**

- [ ] UI state changes confirmed by backend before being shown to user
- [ ] Renamed/removed public symbols have `@available(*, deprecated, renamed:)` aliases
- [ ] Explicit type casts at every Swift/C++ bridge crossing (`Float`/`Double`/`Int32`/`Int64`)
- [ ] No fabricated hardware values — disable UI for unsupported capabilities
- [ ] Structured types used for cross-boundary data, not string-encoded formats

**Minor — fix opportunistically:**

- [ ] Consumer-empty fast-paths before expensive frame allocations/copies
- [ ] No absolute/machine-specific paths in committed config files
- [ ] C++ headers include everything they directly use
- [ ] Platform/ABI restrictions documented with rationale
