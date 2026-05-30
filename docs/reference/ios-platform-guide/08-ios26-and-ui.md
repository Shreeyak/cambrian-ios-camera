# 08 — iOS 26 Platform and UI Lifecycle

Deployment target, Liquid Glass scope, SwiftUI lifecycle rule. Three ADRs — the
platform decisions that shape every SwiftUI file the implementation agent writes.

---

## ADR-26: Deployment target is iOS 26.0; no back-deploy

Minimum iOS version is **26.0**. No `@available(iOS 17, *)` scaffolding, no
`#available` branches for older versions.

### Why

- The camera app ships on new hardware with current iOS. The audience that
  would block a 26-only release is too small to justify the scaffolding tax.
- Back-deploy support doubles the verification surface: every Metal 4 feature,
  every Swift 6.2 concurrency feature, every SwiftUI-26 API needs a fallback
  path. Each fallback is a code path we'd have to test on an older device
  we don't own.
- Agents writing code generate `@available` noise on autopilot. Removing the
  scaffolding is a one-line policy declaration here that prevents it.

### What this unlocks

| Feature | Baseline |
|---|---|
| Swift 6.3 / approachable concurrency (SE-0466) | Compiler 6.2+; Xcode 26 |
| Metal 4 features (argument encoders, resource heaps, mesh shaders) | iOS 18+; Metal 3 minimum |
| SwiftUI `.task` (structured cancellation) | iOS 15+ — not a concern |
| PhotosPicker | iOS 16+ — not a concern |
| Vision modern API (`RecognizeTextRequest` struct-based) | iOS 18+ |
| Liquid Glass | iOS 26 only |
| `UIDesignRequiresCompatibility` opt-in (to retain pre-26 chrome) | iOS 26 — we do **not** opt in |

### Policy

- No `@available(iOS …)` annotations in this project. If an API requires a
  newer iOS than 26, that is a per-API decision logged as a `D-##` — not a
  file-wide attribute.
- `@backDeployed` is never used.
- When a feature arrives in a future iOS (say, iOS 27), the deployment target
  bumps and older API paths are deleted — not `#available`-gated.
- No `.glassEffect()` modifier or `GlassEffectContainer` in this project.
  System chrome (toolbars, buttons, sheets) adopts Liquid Glass automatically
  on iOS 26 — no custom glass code required.

---

## ADR-28: SwiftUI view lifecycle via `.task`, not `onAppear` + manual `Task`

For any async work tied to a SwiftUI view's lifetime — AsyncStream consumers,
data loads, long-running observations — use `.task`, never `onAppear { Task { … } }`.

### Why

- `.task` creates a Swift `Task` bound to the view's lifetime. When the view
  disappears, the Task is automatically **cancelled**. The Task's cancellation
  propagates into any `await` inside it — `AsyncStream` loops exit cleanly,
  `Task.checkCancellation()` fires, child tasks in `withTaskGroup` clean up.
- `onAppear { Task { … } }` spawns an unstructured Task that lives *past*
  view disappearance. Under fast view churn (navigation, sheet
  present/dismiss, tab switches), this leaks tasks — each of them still
  holding actor references, each of them still pumping frames.
- Pair this with ADR-23 (cancellation is enforced): `.task` + `try
  Task.checkCancellation()` per loop iteration gives correct structured
  behavior with zero manual bookkeeping.

### Correct pattern

```swift
struct CameraScreen: View {
    @State private var viewModel = CameraViewModel()

    var body: some View {
        CameraPreview(session: viewModel.session)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { controlBar }
            .task {
                await viewModel.openEngine()       // auto-cancelled on disappear
            }
            .task(id: viewModel.sessionID) {
                for await detection in viewModel.detections {
                    try? Task.checkCancellation()
                    viewModel.apply(detection)
                }
            }
    }
}
```

### Anti-pattern

```swift
// ❌ leaks on navigation pop
.onAppear {
    Task {
        for await detection in viewModel.detections {
            viewModel.apply(detection)
        }
    }
}
.onDisappear {
    // The Task above is never referenced. There is no way to cancel it.
    // It runs until its upstream stream finishes — which may be never.
}
```

### When to use `onAppear` / `onDisappear`

For purely-synchronous side effects only: logging, reporting an analytic event,
imperatively starting a system API that has no async shape (rare at iOS 26).
Any call that takes `async`, any call to a method on an `actor`, any
`AsyncStream` subscription — use `.task`.

### `.task(id:)` and parameter changes

Use the `id:` overload when the Task should restart on value change (new
session, new consumer registration). SwiftUI cancels the old Task and spawns
a new one — the equivalent of "unsubscribe + resubscribe" without manual
lifecycle code.

---

## Cross-cutting note

These ADRs compose:

- **ADR-26** removes `@available` scaffolding so ADR-28's `.task` calls need
  no version guards.
- **ADR-28** pairs with ADR-23 (cancellation) — structured cancellation only
  works if the Task receiving the signal actually checks it.

The implementation agent cites these by ID; if a product decision requires
breaking one of these, it is a `D-##` entry in `design/06-decisions-log.md`
that names the ADR being overridden.
