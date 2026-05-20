# Phase 1B — OpenCV Consumer Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the OpenCV/Canny consumer + the `opencv2` xcframework from the `CameraKit` Swift package. Relocate the Canny C++ source and its Swift wrapper into the `eva-swift-stitch` app target's new `AppCxx/` layer; keep the consumer-join seam (`PixelSinkPool` + `pixel_sink_pool_register`) in the package, vending the pool handle through `engine.getNativePipelineHandle()`. Add a C-ABI parity probe.

**Architecture:** `CameraKitCxx` keeps only `PixelSinkPool` + `CaptureAtomic` (no OpenCV). The Canny consumer compiles in the app target; the app target links `opencv2.xcframework`; the app target's `DisplayViewModel` registers the relocated Canny stub via the Swift API `engine.consumers.registerCallback(stream: .tracker, …)`. A second tiny app-side C++ consumer (`CounterConsumer`) registers via the **raw C-ABI** `pixel_sink_pool_register` against the engine's pool handle — exercising the path Phase 3's Flutter plugin will use.

**Tech Stack:** Swift 6 (strict concurrency), C++20, OpenCV 4.13 (app-side only), Xcode app target with Objective-C bridging header (`SWIFT_OBJC_BRIDGING_HEADER`), Ruby `xcodeproj` gem for project mutations, XcodeBuildMCP for builds/tests on physical iPad.

**Spec source:** `docs/superpowers/specs/2026-05-14-camerakit-flutter-migration-design.md` §1B + §Verification "Phase 1B — OpenCV consumer".

**Baseline (Phase 1A post-state):** 125 passed / 0 failed on Shreeyak's iPad, scheme `eva-swift-stitch`. `CameraKitInterop` temporarily exported as a SwiftPM product (Phase 1A bridge). All 11 UI files in `eva-swift-stitch/UI/`. The Canny consumer (`CannyStubConsumer.cpp` + `CppCannyStub` wrapper) still in the package.

---

## File Inventory

### Package files removed / mutated

- `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp` — **removed** (relocated to app)
- `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h` — `canny_stub_*` declarations removed (move with the source); pool C-ABI + D-11 metrics block preserved
- `CameraKit/Sources/CameraKitCxx/include/module.modulemap` — unchanged (still exports `PixelSinkCallbacks.h` + `PixelSinkMetrics.h`)
- `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift` — `CppCannyStub` Swift wrapper removed (`MARK: - CppCannyStub` section deleted; the rest — `CppPixelSinkPool`, `CppPixelSinkCallbacks`, `CppCaptureAtomic` — stays)
- `CameraKit/Package.swift` — `opencv2` `binaryTarget` removed; `CameraKitCxx` `dependencies: ["opencv2"]` removed; `.library(name: "CameraKitInterop", …)` product **kept** (needed by app's test target — see Task 8)

### App target files created

- `eva-swift-stitch/AppCxx/CannyConsumer.cpp` — moved from package, with `PixelSink` inheritance dropped (the C-ABI thunk is the only caller; the virtual dispatch was dead weight)
- `eva-swift-stitch/AppCxx/CounterConsumer.cpp` — new; minimal non-OpenCV C++ frame counter registered via raw `pixel_sink_pool_register` (C-ABI parity probe)
- `eva-swift-stitch/AppCxx/include/CannyConsumer.h` — new; `canny_stub_*` C-ABI declarations
- `eva-swift-stitch/AppCxx/include/CounterConsumer.h` — new; `counter_consumer_*` C-ABI declarations
- `eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h` — new; `#include`s both above headers
- `eva-swift-stitch/AppCxx/CppCannyStub.swift` — moved from `CameraKitInterop.swift`; same class name + API surface so `DisplayViewModel` callsites are unchanged
- `eva-swift-stitchTests/Stage08CannyTests.swift` — new; relocated `cannyStubConsumerReceivesTrackerFrames` from `Stage08Tests.swift`
- `eva-swift-stitchTests/CABIParityTests.swift` — new; C-ABI parity probe test

### Test files mutated

- `CameraKit/Tests/CameraKitTests/Stage08Tests.swift` — `cannyStubConsumerReceivesTrackerFrames` removed (the only OpenCV-dependent test); the other six tests stay (dual-membered)

### xcodeproj mutations (all via Ruby `xcodeproj` gem)

- App target (`eva-swift-stitch`):
  - Add `Frameworks/opencv2.xcframework` as a framework with **Embed & Sign** (so the device binary carries the OpenCV slice)
  - Add `FRAMEWORK_SEARCH_PATHS = "$(SRCROOT)/Frameworks"`
  - Add `HEADER_SEARCH_PATHS = "$(SRCROOT)/CameraKit/Sources/CameraKitCxx/include"` (so `CounterConsumer.cpp` can `#include <PixelSinkCallbacks.h>`)
  - Add `SWIFT_OBJC_BRIDGING_HEADER = "eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h"`
  - Add `AppCxx/` group with the four new source/header files
  - Add `AppCxx/CannyConsumer.cpp`, `AppCxx/CounterConsumer.cpp`, `AppCxx/CppCannyStub.swift` to **Sources** build phase
  - Add `opencv2.xcframework` to the **Frameworks** build phase + a new **Copy Files (Frameworks)** phase with `RemoveHeadersOnCopy = YES`, `CodeSignOnCopy = YES` (the "Embed & Sign" pair)
  - **Drop** the `CameraKitInterop` `XCSwiftPackageProductDependency` (DisplayViewModel no longer imports it)
- Test target (`eva-swift-stitchTests`):
  - Add `Stage08CannyTests.swift` to **Sources** (single-target, single-membership — Phase 1A precedent: UI- or app-coupled tests live only in app's test target)
  - Add `CABIParityTests.swift` to **Sources** (single-target)
  - **Keep** the `CameraKitInterop` `XCSwiftPackageProductDependency` (still needed for `CppCaptureAtomic` in dual-membered `Stage08Tests.swift`)
  - Add same `HEADER_SEARCH_PATHS` as app target (`CABIParityTests.swift` calls into `CounterConsumer.h` via the bridging header, which `#include`s `<PixelSinkCallbacks.h>`)
  - The test target inherits the app's bridging header automatically when host-app testing — verify after wiring

### Docs

- `CameraKit/CONTRACTS.md` — regenerated via `scripts/regen-contracts.sh` (will reflect that `CppCannyStub` is gone from the package and `canny_stub_*` C-ABI is gone from `PixelSinkCallbacks.h`)
- `CameraKit/state.md` — Phase 1B landing record (new top-section); the Phase 1A entry stays as the prior-state record
- `CameraKit/DECISIONS.md` — append one entry: "OpenCV consumer relocated app-side; `PixelSink` inheritance dropped from CannyConsumer on move because the C-ABI thunk was the only caller"

---

## Design decisions

**Why `CameraKitInterop` product stays exported.** The Phase 1A state.md memo claimed Phase 1B would un-export it, but the dual-membered `Stage08Tests.stillCaptureUsesCppAtomic` still imports `CppCaptureAtomic` from `CameraKitInterop`. Un-exporting would break that test in the Xcode test target. Decision: keep the product exported, drop only the app target's dependency. CLAUDE.md §8's "dual-membered by default" stays intact.

**Why `CannyConsumer` drops its `PixelSink` inheritance on move.** The current `CannyStubConsumer : public PixelSink` is structurally dead — the C-ABI `canny_stub_on_frame` thunk synthesizes a `PixelFrame` and dispatches to the virtual override; nothing else ever calls the virtual. Dropping the inheritance eliminates the `PixelSink.hpp` + `PixelFrame` header dependency, making the move a true byte-relocation with no header search path back into the package needed for `CannyConsumer.cpp`. `CounterConsumer.cpp` does need the search path (for the C-ABI declarations).

**Why no explicit "delete in-package Canny registration" task.** Spec §1B mentions deleting the internal Canny registration call site. A grep confirms there is no such site in the package — `DisplayViewModel.attachAfterOpen` was always the registrant, and Phase 1A relocated it. The spec line was slightly imprecise; no code task needed.

**Why bridging-header rather than module map.** User choice (per AskUserQuestion 2026-05-15). Canonical Xcode app-target pattern; one build-setting change; the header lives inside `AppCxx/` so it travels with the layer when Phase 3 relocates it into the Flutter plugin.

---

## Task 0: Pre-flight verification

**Files:**
- Read: `CameraKit/state.md` (verify Phase 1A landing record is the current top section)

- [ ] **Step 1: Verify the stage-preflight baseline**

```bash
scripts/stage-preflight.sh
```

Expected: exit 0. The script validates state.md ↔ source slug coherence (scaffold corpus is empty post-Stage-12, so this is a fast check), CONTRACTS.md freshness, and a clean build.

- [ ] **Step 2: Snapshot the green test bundle**

Use XcodeBuildMCP to confirm the Phase 1A baseline still passes before any change.

```
mcp__XcodeBuildMCP__session_show_defaults     # verify scheme=eva-swift-stitch, deviceId=Shreeyak's iPad
mcp__XcodeBuildMCP__test_device               # empty args; runs the full bundle
```

Expected: `Test Succeeded` — 125 passed / 0 failed. If anything fails, **stop and surface** to the user; we do not begin Phase 1B on a red baseline.

- [ ] **Step 3: Confirm the relocation inventory has not drifted**

```bash
grep -rn "CppCannyStub\|canny_stub" CameraKit/Sources/ eva-swift-stitch/ CameraKit/Tests/
```

Expected matches (these are the files Phase 1B will touch — anything else means drift):
- `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp` (the C++ file we move)
- `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h` (the `canny_stub_*` declarations we move out)
- `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift` (the `CppCannyStub` Swift wrapper we move)
- `eva-swift-stitch/UI/DisplayViewModel.swift` (the consumer — no change to this file)
- `CameraKit/Tests/CameraKitTests/Stage08Tests.swift` (one test moves to app target)

No commit — preflight only.

---

## Task 1: Drop `PixelSink` inheritance from `CannyStubConsumer` (in-place refactor)

**Files:**
- Modify: `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp`

Why: the C-ABI thunk is the only caller of the virtual `onFrame(const PixelFrame&)`. Dropping the inheritance now (before the move) makes the relocation byte-equivalent, with no dependency on `PixelSink.hpp` / `PixelFrame` from the package. Done as a separate task so a regression here is bisectable.

- [ ] **Step 1: Refactor `CannyStubConsumer` to a self-contained class**

Replace the contents of `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp` with:

```cpp
// CannyStubConsumer — OpenCV-backed Canny edge detection per ADR-29.
// Receives tracker-stream frames via the C-ABI canny_stub_on_frame entrypoint
// (the C++ pool calls it through a PixelSinkCallbacks function pointer).
// Stores (frameNumber, edgePixelCount) tuples into a fixed-size ring buffer
// the debug overlay reads back via canny_stub_processed_count / _edge_count.
// OpenCV is confined to CameraKitCxx; no OpenCV symbol escapes (ADR-11).
//
// Self-contained: does NOT inherit from PixelSink. The C-ABI thunk was the
// only caller of the virtual onFrame override; the inheritance was structurally
// dead. Dropping it removes the PixelSink.hpp / PixelFrame dependency,
// which is required so this file can relocate to the app target in Phase 1B.
#include "PixelSinkCallbacks.h"
#include <opencv2/imgproc.hpp>
#include <opencv2/core.hpp>
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <os/log.h>
#include <atomic>
#include <array>
#include <cstdint>

static os_log_t cannyLog() {
    static os_log_t l = os_log_create("com.cambrian.camerakit", "CannyStub");
    return l;
}

static constexpr size_t kRingSize    = 64;
static constexpr double kCannyLow    = 50.0;
static constexpr double kCannyHigh   = 150.0;

struct CannyRingEntry {
    uint64_t frameNumber;
    uint32_t stream;
    uint32_t edgePixelCount;
};

class CannyStubConsumer {
public:
    void onFrame(uint32_t stream, uint64_t frameNumber, void* surface) {
        uint32_t edgeCount = 0;
        if (surface != nullptr) {
            edgeCount = runCanny(static_cast<IOSurfaceRef>(surface));
        }
        uint64_t idx = writeIdx_.fetch_add(1, std::memory_order_relaxed);
        ring_[idx % kRingSize] = {frameNumber, stream, edgeCount};
        // Log every 30 frames (~1 s at 30 fps) — gated by os_log level at runtime.
        if (idx % 30 == 0) {
            os_log(cannyLog(), "frame=%llu stream=%u edges=%u total=%llu",
                   frameNumber, stream, edgeCount, idx + 1);
        }
    }

    uint64_t processedCount() const {
        return writeIdx_.load(std::memory_order_relaxed);
    }

    uint32_t edgeCountAt(size_t idx) const {
        if (idx >= kRingSize) { return 0; }
        return ring_[idx].edgePixelCount;
    }

private:
    uint32_t runCanny(IOSurfaceRef surface) {
        CVPixelBufferRef pb = nullptr;
        CVReturn r = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, nullptr, &pb);
        if (r != kCVReturnSuccess || pb == nullptr) { return 0; }

        uint32_t edges = 0;
        if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
            void* base   = CVPixelBufferGetBaseAddress(pb);
            size_t w     = CVPixelBufferGetWidth(pb);
            size_t h     = CVPixelBufferGetHeight(pb);
            size_t stride = CVPixelBufferGetBytesPerRow(pb);
            OSType fmt   = CVPixelBufferGetPixelFormatType(pb);

            if (base != nullptr && w > 0 && h > 0) {
                cv::Mat gray;
                if (fmt == kCVPixelFormatType_OneComponent8) {
                    cv::Mat src(static_cast<int>(h), static_cast<int>(w),
                                CV_8UC1, base, stride);
                    gray = src;
                } else if (fmt == kCVPixelFormatType_32BGRA) {
                    cv::Mat src(static_cast<int>(h), static_cast<int>(w),
                                CV_8UC4, base, stride);
                    cv::cvtColor(src, gray, cv::COLOR_BGRA2GRAY);
                } else if (fmt == kCVPixelFormatType_64RGBAHalf) {
                    // Tracker pool uses 64-bit RGBA half-float (kCVPixelFormatType_64RGBAHalf).
                    // Convert: half-float → 32F → grayscale → 8-bit for Canny.
                    cv::Mat src16(static_cast<int>(h), static_cast<int>(w),
                                  CV_16FC4, base, stride);
                    cv::Mat src32;
                    src16.convertTo(src32, CV_32FC4);
                    cv::Mat gray32;
                    cv::cvtColor(src32, gray32, cv::COLOR_RGBA2GRAY);
                    gray32.convertTo(gray, CV_8UC1, 255.0);
                } else {
                    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                    CVPixelBufferRelease(pb);
                    return 0;
                }

                cv::Mat edgesMat;
                cv::Canny(gray, edgesMat, kCannyLow, kCannyHigh);
                edges = static_cast<uint32_t>(cv::countNonZero(edgesMat));
            }
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        }
        CVPixelBufferRelease(pb);
        return edges;
    }

    std::atomic<uint64_t>                  writeIdx_{0};
    std::array<CannyRingEntry, kRingSize>  ring_{};
};

extern "C" {

void* canny_stub_create(void) { return new CannyStubConsumer(); }

void canny_stub_destroy(void* handle) {
    delete static_cast<CannyStubConsumer*>(handle);
}

void canny_stub_on_frame(void* context, uint32_t stream, uint64_t frameNumber,
                         int64_t /*presentationTimeNs*/, void* surface) {
    static_cast<CannyStubConsumer*>(context)->onFrame(stream, frameNumber, surface);
}

uint64_t canny_stub_processed_count(void* handle) {
    return static_cast<CannyStubConsumer*>(handle)->processedCount();
}

uint32_t canny_stub_edge_count(void* handle, size_t idx) {
    return static_cast<CannyStubConsumer*>(handle)->edgeCountAt(idx);
}

}  // extern "C"
```

Changes from the prior version:
- No `#include "PixelSink.hpp"`
- Class no longer inherits from `PixelSink`; no `override`; no `onOverwrite` (the C-ABI doesn't need it — the pool delivers overwrites through a separate `on_overwrite` callback which Canny never wired up anyway)
- `onFrame` now takes `(stream, frameNumber, surface)` directly — no `PixelFrame` intermediate
- The C-ABI thunk no longer builds a `PixelFrame`

- [ ] **Step 2: Build the package headless**

```
mcp__XcodeBuildMCP__build_device              # empty args; uses session defaults
```

Expected: `Build Succeeded`. `CameraKitCxx` recompiles `CannyStubConsumer.cpp` without `PixelSink.hpp`.

- [ ] **Step 3: Run the full test bundle**

```
mcp__XcodeBuildMCP__test_device
```

Expected: `Test Succeeded` — 125 passed / 0 failed. Stage08's `cannyStubConsumerReceivesTrackerFrames` still passes because it never relied on the inheritance — only on the C-ABI symbols and `processedCount`.

- [ ] **Step 4: Commit**

```bash
git add CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp
git commit -m "refactor(canny): drop dead PixelSink inheritance before Phase 1B move"
```

---

## Task 2: Create the app's `AppCxx/` layer skeleton (headers + bridging header)

**Files:**
- Create: `eva-swift-stitch/AppCxx/include/CannyConsumer.h`
- Create: `eva-swift-stitch/AppCxx/include/CounterConsumer.h`
- Create: `eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h`

This task creates the headers only — no `.cpp` or `.swift` yet. Splitting headers from sources keeps the diff small and verifiable.

- [ ] **Step 1: Write the Canny consumer header**

```bash
mkdir -p eva-swift-stitch/AppCxx/include
```

Create `eva-swift-stitch/AppCxx/include/CannyConsumer.h`:

```c
// CannyConsumer — C-ABI for the OpenCV-backed Canny edge detection consumer.
// Phase 1B (2026-05-15) — relocated from CameraKitCxx/CannyStubConsumer.cpp.
// Names preserved (canny_stub_*) so existing DisplayViewModel callsites
// are unchanged on the Swift side.
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void*    canny_stub_create(void);
void     canny_stub_destroy(void* handle);
void     canny_stub_on_frame(void* context, uint32_t stream, uint64_t frameNumber,
                             int64_t presentationTimeNs, void* surface);
uint64_t canny_stub_processed_count(void* handle);
uint32_t canny_stub_edge_count(void* handle, size_t idx);

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 2: Write the Counter consumer header (C-ABI parity probe)**

Create `eva-swift-stitch/AppCxx/include/CounterConsumer.h`:

```c
// CounterConsumer — minimal C++ consumer for the C-ABI parity probe.
// Phase 1B (2026-05-15). Counts frames per stream; no image processing,
// no OpenCV. Registered against the engine's raw pool pointer via
// pixel_sink_pool_register — the exact path Phase 3's Flutter plugin
// native code will use.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Create / destroy a CounterConsumer instance.
void* counter_consumer_create(void);
void  counter_consumer_destroy(void* handle);

// Register this counter against the pool at `rawPoolPtr` (the value returned
// by pixel_sink_pool_raw_pointer, i.e. CameraEngine.getNativePipelineHandle()).
// Returns the token from pixel_sink_pool_register (0 = rejection).
uint64_t counter_consumer_register(void* handle, void* rawPoolPtr, uint32_t stream);

// Unregister using the prior register() token.
void counter_consumer_unregister(void* handle, void* rawPoolPtr, uint64_t token);

// Frames observed on this consumer (cumulative).
uint64_t counter_consumer_frame_count(void* handle);

// Last frame number observed (0 if none).
uint64_t counter_consumer_last_frame_number(void* handle);

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 3: Write the bridging header**

Create `eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h`:

```c
// AppCxx bridging header — exposes the app-target C-ABI to Swift.
// Phase 1B (2026-05-15). Set as SWIFT_OBJC_BRIDGING_HEADER on the
// eva-swift-stitch app target only. Test target inherits via host-app.
#pragma once
#include "include/CannyConsumer.h"
#include "include/CounterConsumer.h"
```

No build or commit yet — the files are not in the xcodeproj yet. Combined commit at Task 4.

---

## Task 3: Move the Canny C++ source into `AppCxx/`

**Files:**
- Create: `eva-swift-stitch/AppCxx/CannyConsumer.cpp` (content equals Task 1's refactored CannyStubConsumer.cpp)
- Delete: `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp`

- [ ] **Step 1: Move the file with `git mv`**

```bash
git mv CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp \
       eva-swift-stitch/AppCxx/CannyConsumer.cpp
```

`git mv` preserves history; no content change.

- [ ] **Step 2: Update the include directive**

The Task-1 file used `#include "PixelSinkCallbacks.h"`. After the move, the file's app-side context means it no longer needs anything from `PixelSinkCallbacks.h` (it dropped the `PixelSink` inheritance and uses no C-ABI types from there — only `IOSurfaceRef` from CoreVideo and `cv::*` from OpenCV).

Open `eva-swift-stitch/AppCxx/CannyConsumer.cpp` and remove the line:

```cpp
#include "PixelSinkCallbacks.h"
```

Replace it with the new local header so the file's C-ABI declarations match its definitions:

```cpp
#include "include/CannyConsumer.h"
```

Verify with:

```bash
grep -n "include " eva-swift-stitch/AppCxx/CannyConsumer.cpp | head
```

Expected includes:
- `"include/CannyConsumer.h"`
- `<opencv2/imgproc.hpp>`
- `<opencv2/core.hpp>`
- `<CoreVideo/CoreVideo.h>`
- `<CoreFoundation/CoreFoundation.h>`
- `<os/log.h>`
- `<atomic>`, `<array>`, `<cstdint>`

No build yet — the xcodeproj doesn't see the file, and `Package.swift` still references the old path. Combined commit at Task 4.

---

## Task 4: Write the Counter consumer source

**Files:**
- Create: `eva-swift-stitch/AppCxx/CounterConsumer.cpp`

- [ ] **Step 1: Write the counter consumer**

Create `eva-swift-stitch/AppCxx/CounterConsumer.cpp`:

```cpp
// CounterConsumer — minimal C-ABI parity probe per Phase 1B.
// Counts frames per stream; no image processing. Registered against the
// engine's raw pool pointer via the C-ABI pixel_sink_pool_register, exactly
// as Phase 3's Flutter plugin native code will.
#include "include/CounterConsumer.h"
#include <PixelSinkCallbacks.h>   // from CameraKit/Sources/CameraKitCxx/include
                                   // via HEADER_SEARCH_PATHS (Task 6)
#include <atomic>
#include <cstdint>

class CounterConsumer {
public:
    void onFrame(uint64_t frameNumber) {
        frameCount_.fetch_add(1, std::memory_order_relaxed);
        lastFrameNumber_.store(frameNumber, std::memory_order_relaxed);
    }

    uint64_t frameCount() const {
        return frameCount_.load(std::memory_order_relaxed);
    }

    uint64_t lastFrameNumber() const {
        return lastFrameNumber_.load(std::memory_order_relaxed);
    }

private:
    std::atomic<uint64_t> frameCount_{0};
    std::atomic<uint64_t> lastFrameNumber_{0};
};

// MARK: - C-ABI

extern "C" {

void* counter_consumer_create(void) { return new CounterConsumer(); }

void counter_consumer_destroy(void* handle) {
    delete static_cast<CounterConsumer*>(handle);
}

// Static C-ABI trampolines for pixel_sink_pool_register.
// on_frame writes to the CounterConsumer at `context`.
static void counter_on_frame(void* context, uint32_t /*stream*/,
                             uint64_t frameNumber, int64_t /*presentationTimeNs*/,
                             void* /*surface*/) {
    static_cast<CounterConsumer*>(context)->onFrame(frameNumber);
}

// on_overwrite is required by the G-26 gate; no-op for the counter.
static void counter_on_overwrite(void* /*context*/, uint32_t /*stream*/) {}

// on_error is optional per D-03; provided as a no-op.
static void counter_on_error(void* /*context*/, int32_t /*code*/) {}

uint64_t counter_consumer_register(void* handle, void* rawPoolPtr, uint32_t stream) {
    if (handle == nullptr || rawPoolPtr == nullptr) { return 0; }
    PixelSinkCallbacks cbs;
    cbs.on_frame     = counter_on_frame;
    cbs.on_overwrite = counter_on_overwrite;
    cbs.on_error     = counter_on_error;
    cbs.context      = handle;
    return pixel_sink_pool_register(rawPoolPtr, stream, cbs);
}

void counter_consumer_unregister(void* /*handle*/, void* rawPoolPtr, uint64_t token) {
    if (rawPoolPtr == nullptr || token == 0) { return; }
    pixel_sink_pool_unregister(rawPoolPtr, token);
}

uint64_t counter_consumer_frame_count(void* handle) {
    return static_cast<CounterConsumer*>(handle)->frameCount();
}

uint64_t counter_consumer_last_frame_number(void* handle) {
    return static_cast<CounterConsumer*>(handle)->lastFrameNumber();
}

}  // extern "C"
```

This file is **inert** until linked — no symbols clash, no headers are referenced from the package's own targets. The `#include <PixelSinkCallbacks.h>` requires `HEADER_SEARCH_PATHS` to include `$(SRCROOT)/CameraKit/Sources/CameraKitCxx/include`; that is added in Task 6.

No build yet. Combined commit at Task 7.

---

## Task 5: Move the `CppCannyStub` Swift wrapper into `AppCxx/`

**Files:**
- Create: `eva-swift-stitch/AppCxx/CppCannyStub.swift`
- Modify: `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift` — remove the `// MARK: - CppCannyStub` section and the `CppCannyStub` class

- [ ] **Step 1: Write the relocated `CppCannyStub`**

Create `eva-swift-stitch/AppCxx/CppCannyStub.swift`:

```swift
// CppCannyStub — Swift wrapper over the AppCxx Canny consumer C-ABI.
// Phase 1B (2026-05-15) — relocated from CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift.
// API surface preserved so DisplayViewModel callsites are unchanged.
//
// The canny_stub_* C-ABI symbols come from AppCxx/CannyConsumer.cpp and are
// exposed to Swift via AppCxx-Bridging-Header.h (SWIFT_OBJC_BRIDGING_HEADER
// on the eva-swift-stitch target).
import CameraKit         // PixelSinkCallbacks (Swift-side struct, type for engine.consumers.registerCallback)
import Foundation
import OSLog

private let log = Logger(subsystem: "com.cambrian.camerakit", category: "appcxx")

/// OpenCV-backed Canny stub consumer (ring buffer of edge counts per ADR-29).
public final class CppCannyStub: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    public init() {
        handle = canny_stub_create()!
        log.info("CppCannyStub: created")
    }

    deinit {
        let count = canny_stub_processed_count(handle)
        log.info("CppCannyStub: destroying — total frames processed: \(count)")
        canny_stub_destroy(handle)
    }

    public var processedCount: UInt64 { canny_stub_processed_count(handle) }

    /// Edge pixel count at ring-buffer index idx (0 ..< 64) for debug overlay.
    public func edgeCount(at idx: Int) -> UInt32 {
        canny_stub_edge_count(handle, idx)
    }

    /// Returns the C-ABI on_frame function pointer for use with `PixelSinkCallbacks`.
    public func onFrameCallback()
        -> @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt64, Int64, UnsafeMutableRawPointer?) -> Void
    {
        { ctx, stream, frame, ts, surface in canny_stub_on_frame(ctx, stream, frame, ts, surface) }
    }

    /// Opaque C++ handle for use as the `context` field of `PixelSinkCallbacks`.
    public var nativeContext: UnsafeMutableRawPointer? { handle }
}
```

Differences from the package version:
- No `import CameraKitCxx` (the C-ABI now comes through the app's bridging header, not the package's C++ module)
- The `makeCallbacks()` helper is **dropped**. The only caller in the codebase is the package's `Stage08Tests.cannyStubConsumerReceivesTrackerFrames`, which we relocate in Task 9 and which constructs `PixelSinkCallbacks` directly (it never used `makeCallbacks()` — verify with `grep -rn 'makeCallbacks' .`)
- Logger subsystem unchanged; category changed from `"interop"` to `"appcxx"` so app-side AppCxx logs are distinguishable from the package's interop logs in Console.app

- [ ] **Step 2: Verify `makeCallbacks()` has no callers**

```bash
grep -rn "makeCallbacks" CameraKit/ eva-swift-stitch/ eva-swift-stitchTests/
```

Expected: 0 hits. If any hits surface, **stop** and surface to the user — the API was used somewhere we didn't see and the wrapper needs to keep it.

- [ ] **Step 3: Remove `CppCannyStub` from `CameraKitInterop.swift`**

Open `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift`. Find the section starting at the `// MARK: - CppCannyStub` line (line 167 in the post-Phase-1A file) and ending at the closing brace of `CppCannyStub` (currently the last symbol in the file, line 212). Delete that range — from `// MARK: - CppCannyStub` through the final `}`.

The file should end with `CppCaptureAtomic`'s closing brace.

Verify:

```bash
grep -n "MARK: -" CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift
```

Expected:
- `MARK: - CppPixelSinkPool`
- `MARK: - D-11 observability`
- `MARK: - CppPixelSinkCallbacks`
- `MARK: - CppCaptureAtomic`

(No `MARK: - CppCannyStub`.)

- [ ] **Step 4: Verify the file compiles inside the package**

Don't run a full build yet (the xcodeproj-side `AppCxx/CppCannyStub.swift` isn't linked). Use the package-only build path:

```
mcp__XcodeBuildMCP__build_device
```

Expected: **fails** at `DisplayViewModel.swift` — `CppCannyStub` no longer resolves because `CameraKitInterop` no longer defines it. **This is the expected intermediate state.** The next tasks (6–8) reconnect it via the app's `AppCxx/`.

(If you want a sanity check of just the package's library targets — e.g. while writing — use `scripts/dump-interface.sh` which can emit `.swiftinterface` even with consumer-side errors.)

No commit yet. Combined commit at Task 7 after the xcodeproj is wired and the build returns green.

---

## Task 6: Add `AppCxx/` to the xcodeproj (sources, headers, build settings)

**Files:**
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (via Ruby `xcodeproj` gem)

CLAUDE.md §6 forbids hand-editing `project.pbxproj`. All mutations go through the gem. CLAUDE.md §8's xcodeproj-gotcha note applies: SPM products use `product_ref`, not `fileRef` — relevant in Task 8 below; this task touches sources/headers/settings only.

- [ ] **Step 1: Write the project-mutation script**

Create a one-shot script `/tmp/phase1b-appcxx.rb`:

```ruby
require 'xcodeproj'

PROJECT = 'eva-swift-stitch.xcodeproj'
APP_TARGET = 'eva-swift-stitch'

p = Xcodeproj::Project.open(PROJECT)
app = p.targets.find { |t| t.name == APP_TARGET } or abort "app target not found"

# --- Groups ---
root = p.main_group['eva-swift-stitch'] or abort "eva-swift-stitch group not found"
appcxx = root['AppCxx'] || root.new_group('AppCxx', 'AppCxx')
include_grp = appcxx['include'] || appcxx.new_group('include', 'include')

# --- File refs (idempotent: skip if already present by path) ---
def ensure_file(group, path, type)
  existing = group.files.find { |f| f.path == path }
  return existing if existing
  group.new_file(path).tap { |fr| fr.last_known_file_type = type }
end

canny_cpp     = ensure_file(appcxx,     'CannyConsumer.cpp',         'sourcecode.cpp.cpp')
counter_cpp   = ensure_file(appcxx,     'CounterConsumer.cpp',       'sourcecode.cpp.cpp')
canny_stub_sw = ensure_file(appcxx,     'CppCannyStub.swift',        'sourcecode.swift')
bridging_h    = ensure_file(appcxx,     'AppCxx-Bridging-Header.h',  'sourcecode.c.h')
canny_h       = ensure_file(include_grp,'CannyConsumer.h',           'sourcecode.c.h')
counter_h     = ensure_file(include_grp,'CounterConsumer.h',         'sourcecode.c.h')

# --- Sources build phase (skip if already added) ---
sources = app.source_build_phase
[canny_cpp, counter_cpp, canny_stub_sw].each do |fr|
  next if sources.files.any? { |bf| bf.file_ref == fr }
  sources.add_file_reference(fr)
end

# --- Build settings (Debug + Release) ---
app.build_configurations.each do |cfg|
  bs = cfg.build_settings

  # Bridging header
  bs['SWIFT_OBJC_BRIDGING_HEADER'] = 'eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h'

  # Header search paths — non-recursive, additive
  existing_hsp = Array(bs['HEADER_SEARCH_PATHS'])
  hsp_addition = '$(SRCROOT)/CameraKit/Sources/CameraKitCxx/include'
  unless existing_hsp.include?(hsp_addition) || existing_hsp.include?('$(inherited)') && existing_hsp.include?(hsp_addition)
    bs['HEADER_SEARCH_PATHS'] = (['$(inherited)'] + existing_hsp + [hsp_addition]).uniq
  end

  # Framework search paths
  existing_fsp = Array(bs['FRAMEWORK_SEARCH_PATHS'])
  fsp_addition = '$(SRCROOT)/Frameworks'
  unless existing_fsp.include?(fsp_addition)
    bs['FRAMEWORK_SEARCH_PATHS'] = (['$(inherited)'] + existing_fsp + [fsp_addition]).uniq
  end

  # C++ standard — app target already at gnu++20 per pbxproj L472, but assert for safety
  bs['CLANG_CXX_LANGUAGE_STANDARD'] ||= 'gnu++20'
end

p.save
puts "AppCxx wired into #{APP_TARGET}"
```

- [ ] **Step 2: Run the script**

```bash
ruby /tmp/phase1b-appcxx.rb
```

Expected output: `AppCxx wired into eva-swift-stitch`.

- [ ] **Step 3: Sanity-check the diff**

```bash
git diff --stat eva-swift-stitch.xcodeproj/project.pbxproj
```

Expected: a small change (~30–60 lines added) — file refs, build files, sources entries, and three build settings on each config.

```bash
grep -n "AppCxx\|AppCxx-Bridging-Header\|SWIFT_OBJC_BRIDGING_HEADER" eva-swift-stitch.xcodeproj/project.pbxproj | head -20
```

Expected: matches for the new file refs, the bridging header reference, and the bridging-header build setting (Debug + Release).

No commit yet. Combined commit at Task 7 once the build is green.

---

## Task 7: Link `opencv2.xcframework` into the app target with Embed & Sign

**Files:**
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (via gem)

The package's `Package.swift` still references `opencv2` at this point — we don't remove that until Task 9. Adding the xcframework to the app target first means the app self-contains its OpenCV linkage before we sever the package's.

- [ ] **Step 1: Write the framework-link script**

Create `/tmp/phase1b-opencv.rb`:

```ruby
require 'xcodeproj'

PROJECT = 'eva-swift-stitch.xcodeproj'
APP_TARGET = 'eva-swift-stitch'

p = Xcodeproj::Project.open(PROJECT)
app = p.targets.find { |t| t.name == APP_TARGET } or abort "app target not found"

# --- File ref for opencv2.xcframework ---
# Place it under a top-level Frameworks group (create if missing).
frameworks_grp = p.main_group['Frameworks'] || p.main_group.new_group('Frameworks', 'Frameworks')
opencv_ref = frameworks_grp.files.find { |f| f.path == 'opencv2.xcframework' }
unless opencv_ref
  opencv_ref = frameworks_grp.new_file('opencv2.xcframework')
  opencv_ref.last_known_file_type = 'wrapper.xcframework'
end

# --- Link in Frameworks build phase ---
fb = app.frameworks_build_phase
unless fb.files.any? { |bf| bf.file_ref == opencv_ref }
  fb.add_file_reference(opencv_ref)
end

# --- Embed & Sign via PBXCopyFilesBuildPhase (dstSubfolderSpec=10 = Frameworks dir) ---
embed_phase = app.copy_files_build_phases.find { |ph| ph.symbol_dst_subfolder_spec == :frameworks }
unless embed_phase
  embed_phase = app.new_copy_files_build_phase('Embed Frameworks')
  embed_phase.symbol_dst_subfolder_spec = :frameworks
  embed_phase.dst_path = ''
end

unless embed_phase.files.any? { |bf| bf.file_ref == opencv_ref }
  bf = embed_phase.add_file_reference(opencv_ref)
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

p.save
puts "opencv2.xcframework linked + embedded into #{APP_TARGET}"
```

- [ ] **Step 2: Run the script**

```bash
ruby /tmp/phase1b-opencv.rb
```

Expected output: `opencv2.xcframework linked + embedded into eva-swift-stitch`.

- [ ] **Step 3: Build the app**

```
mcp__XcodeBuildMCP__build_device
```

Expected: `Build Succeeded`. This is the moment of truth — the app now compiles:
- `AppCxx/CannyConsumer.cpp` (with the new local header)
- `AppCxx/CounterConsumer.cpp` (uses `<PixelSinkCallbacks.h>` via HEADER_SEARCH_PATHS)
- `AppCxx/CppCannyStub.swift` (uses `canny_stub_*` via the bridging header)
- `eva-swift-stitch/UI/DisplayViewModel.swift` resolves `CppCannyStub` from the app target's own module instead of `import CameraKitInterop`

If the build fails with "Cannot find symbol `canny_stub_*`": verify `SWIFT_OBJC_BRIDGING_HEADER` is set on both Debug + Release configs and the path is `eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h`.

If it fails with "Cannot find `PixelSinkCallbacks.h`": verify HEADER_SEARCH_PATHS includes `$(SRCROOT)/CameraKit/Sources/CameraKitCxx/include` on both configs.

If it fails on `DisplayViewModel.swift` with "Cannot find type CppCannyStub": confirm the new `AppCxx/CppCannyStub.swift` is in the Sources build phase (grep the pbxproj for `CppCannyStub.swift in Sources`).

- [ ] **Step 4: Run the test bundle**

```
mcp__XcodeBuildMCP__test_device
```

Expected: 125 passed / 0 failed. `Stage08Tests.cannyStubConsumerReceivesTrackerFrames` still passes — it imports `CameraKitInterop` for `CppCannyStub`, which is **still there** at this point (we don't remove the package version until Task 5 lands as part of this commit). Wait — Task 5 already removed it. So this test should **fail** at this point because it can't resolve `CppCannyStub`. Yes — this is expected. The fix is in Task 9 (moving that test out). Hold off on the commit until Task 9 is done.

Actually, this means the build-green checkpoint must be split: build success at Step 3 is fine; full test-green has to wait for Task 9. So:

- [ ] **Step 5: Commit the wired state (build-green, test-not-yet-green is expected)**

```bash
git add eva-swift-stitch.xcodeproj/project.pbxproj \
        eva-swift-stitch/AppCxx/ \
        CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp \
        CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift
git status   # verify CannyStubConsumer.cpp is recorded as a rename to eva-swift-stitch/AppCxx/CannyConsumer.cpp
git commit -m "feat(phase-1b): relocate Canny consumer + xcframework to app target

- CannyStubConsumer.cpp -> eva-swift-stitch/AppCxx/CannyConsumer.cpp (git mv)
- CppCannyStub Swift wrapper -> eva-swift-stitch/AppCxx/CppCannyStub.swift
- New CounterConsumer.cpp (C-ABI parity probe scaffolding)
- opencv2.xcframework linked + embed-signed on app target
- New AppCxx-Bridging-Header.h exposes canny_stub_* + counter_consumer_*
- App target gains HEADER_SEARCH_PATHS + FRAMEWORK_SEARCH_PATHS

Build green; Stage08Tests still imports CppCannyStub from CameraKitInterop
and fails — fix in next commit (test relocation)."
```

---

## Task 8: Drop the app target's `CameraKitInterop` product dependency

**Files:**
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (via gem)

After Task 7, `DisplayViewModel.swift` no longer needs `import CameraKitInterop` (it gets `CppCannyStub` from the app target's own module). The test target keeps its dependency for `CppCaptureAtomic`.

- [ ] **Step 1: Confirm `DisplayViewModel.swift` does not import `CameraKitInterop`**

```bash
grep -n "import CameraKitInterop" eva-swift-stitch/UI/*.swift eva-swift-stitch/*.swift eva-swift-stitch/AppCxx/*.swift
```

Expected: 0 hits in the app target sources.

- [ ] **Step 2: Write the dependency-removal script**

Create `/tmp/phase1b-drop-interop-from-app.rb`:

```ruby
require 'xcodeproj'

PROJECT = 'eva-swift-stitch.xcodeproj'
APP_TARGET = 'eva-swift-stitch'

p = Xcodeproj::Project.open(PROJECT)
app = p.targets.find { |t| t.name == APP_TARGET } or abort "app target not found"

# Remove CameraKitInterop from packageProductDependencies
removed = app.package_product_dependencies.reject! { |d| d.product_name == 'CameraKitInterop' }
abort "CameraKitInterop product dep not found on #{APP_TARGET}" unless removed

# Remove the matching entry from the Frameworks build phase (it linked through the product)
fb = app.frameworks_build_phase
fb.files.delete_if do |bf|
  # SPM product deps appear in frameworks phase with product_ref pointing to the dep
  bf.respond_to?(:product_ref) && bf.product_ref && bf.product_ref.product_name == 'CameraKitInterop'
end

p.save
puts "Dropped CameraKitInterop product dep from #{APP_TARGET}"
```

- [ ] **Step 3: Run the script**

```bash
ruby /tmp/phase1b-drop-interop-from-app.rb
```

Expected output: `Dropped CameraKitInterop product dep from eva-swift-stitch`.

- [ ] **Step 4: Verify the test target's dependency is still present**

```bash
grep -n "CameraKitInterop" eva-swift-stitch.xcodeproj/project.pbxproj | head -10
```

Expected: matches under the `eva-swift-stitchTests` target's `packageProductDependencies`, but **none** under the `eva-swift-stitch` (app) target. There should still be one `XCSwiftPackageProductDependency` entry for `CameraKitInterop` (the one consumed by the test target).

- [ ] **Step 5: Build the app**

```
mcp__XcodeBuildMCP__build_device
```

Expected: `Build Succeeded`. The app no longer links `CameraKitInterop` — only `CameraKit`. (The test target still links both.)

No commit yet — Task 9 follows in the same commit (test relocation that makes the test bundle green again).

---

## Task 9: Relocate the Canny test to the app target

**Files:**
- Modify: `CameraKit/Tests/CameraKitTests/Stage08Tests.swift` — remove `cannyStubConsumerReceivesTrackerFrames`
- Create: `eva-swift-stitchTests/Stage08CannyTests.swift`
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (via gem) — add new test file to test target

Per CLAUDE.md §8 + Phase 1A precedent: test files whose dependencies live only in the app target stay **single-membered** (Xcode test target only, not dual-membered). The relocated test imports the app-target `CppCannyStub`, so it cannot compile in the SwiftPM `.testTarget`. That's why `Stage08CannyTests.swift` lives only under `eva-swift-stitchTests/`.

- [ ] **Step 1: Write the relocated test**

Create `eva-swift-stitchTests/Stage08CannyTests.swift`:

```swift
// Stage08CannyTests — relocated from CameraKit/Tests/CameraKitTests/Stage08Tests.swift
// Phase 1B (2026-05-15). `cannyStubConsumerReceivesTrackerFrames` moved here
// because CppCannyStub now lives in the eva-swift-stitch app target (AppCxx/).
// Single-target membership (app-test only) by deliberate exception to CLAUDE.md §8
// — same pattern as Phase 1A's Stage11UITests.swift.
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CameraKit
// No `import CameraKitInterop` — CppCannyStub now resolves from the app target itself.

@Suite("Stage 08 Canny (app-target)", .progressLogged)
struct Stage08CannyTests {

    private func makeSyntheticFrameSet(frameNumber: UInt64 = 1) throws -> FrameSet {
        let width = 64
        let height = 48
        func makeBuffer() throws -> CVPixelBuffer {
            var buf: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let status = CVPixelBufferCreate(
                nil, width, height,
                kCVPixelFormatType_64RGBAHalf,
                attrs as CFDictionary, &buf)
            guard status == kCVReturnSuccess, let b = buf else {
                throw NSError(domain: "test", code: Int(status))
            }
            return b
        }
        return FrameSet(
            frameNumber: frameNumber,
            captureTime: CMTime(value: 1000, timescale: 1_000_000_000),
            natural: try makeBuffer(),
            processed: try makeBuffer(),
            tracker: try makeBuffer(),
            capture: .placeholder(),
            processing: ProcessingMetadata(
                color: ColorUniform(.identity),
                crop: CropUniform.full(width: width, height: height)),
            blurScore: 0,
            trackerQuality: .good
        )
    }

    /// CppCannyStub registered as a C-ABI consumer receives tracker-stream frames.
    @Test("08:canny-stub-consumer-receives-tracker-frames")
    func cannyStubConsumerReceivesTrackerFrames() async throws {
        let registry = ConsumerRegistry()
        let stub = CppCannyStub()
        // Wire CppCannyStub's C-ABI on_frame through the Unmanaged context — same
        // pattern as the original test in Stage08Tests.swift.
        let counter = LockingCounter()
        let cbs = PixelSinkCallbacks(
            onFrame: { ctx, _, _, _, _ in
                Unmanaged<LockingCounter>.fromOpaque(ctx!).takeUnretainedValue().increment()
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(counter).toOpaque()
        )
        let token = try await registry.registerCallback(stream: .tracker, callbacks: cbs)

        for i: UInt64 in 1...10 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter.value == 10)
        // CppCannyStub exists and its processedCount API is exercised (HITL feeds real IOSurfaces).
        _ = stub.processedCount

        await registry.unregister(token: token)
    }
}

// MARK: - Test helpers (local copy — kept package-private in Stage08Tests.swift)

private final class LockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}
```

Note: `.progressLogged` is the project's custom test trait (from `TestProgressLog.swift`, which is in the test target). It resolves because that file is already a member of `eva-swift-stitchTests`.

- [ ] **Step 2: Remove the relocated test from the package**

Open `CameraKit/Tests/CameraKitTests/Stage08Tests.swift`. Find the `// MARK: - 08:canny-stub-consumer-receives-tracker-frames` section (currently around line 76) and the `@Test("08:canny-stub-consumer-receives-tracker-frames")` function `cannyStubConsumerReceivesTrackerFrames()` below it. Delete the section header comment + the doc comment + the test function — through the closing `}` of the test method (around line 109).

Verify:

```bash
grep -n "cannyStub\|canny-stub" CameraKit/Tests/CameraKitTests/Stage08Tests.swift
```

Expected: 0 hits. The file should still have 6 tests: `cppPixelSinkRegistrationRoundtrip`, `getNativePipelineHandleHoldsActor`, `cABICallbacksWithoutOnFrameRejected`, `lockOrderPipelineStageConsumer`, `stillCaptureUsesCppAtomic`, `swiftSubscribeIsFacadeOverCppPool`.

Also remove the now-orphaned doc comment block above the deleted test. Use `swift-format` (`scripts/dump-interface.sh` runs it transitively; or run the pre-commit hook) to catch any orphaned comment-trailing-whitespace issues.

- [ ] **Step 3: Add the new test file to the Xcode test target**

The Phase 1A pattern is `scripts/sync-test-target.sh` (idempotent), but that script syncs `CameraKit/Tests/CameraKitTests/` into the test target. Our new file lives at `eva-swift-stitchTests/`, which `sync-test-target.sh` doesn't manage. So we add it via the gem.

Create `/tmp/phase1b-add-canny-test.rb`:

```ruby
require 'xcodeproj'

PROJECT = 'eva-swift-stitch.xcodeproj'
TEST_TARGET = 'eva-swift-stitchTests'

p = Xcodeproj::Project.open(PROJECT)
tt = p.targets.find { |t| t.name == TEST_TARGET } or abort "test target not found"

tests_grp = p.main_group['eva-swift-stitchTests'] || p.main_group.new_group(TEST_TARGET, TEST_TARGET)

fr = tests_grp.files.find { |f| f.path == 'Stage08CannyTests.swift' }
unless fr
  fr = tests_grp.new_file('Stage08CannyTests.swift')
  fr.last_known_file_type = 'sourcecode.swift'
end

unless tt.source_build_phase.files.any? { |bf| bf.file_ref == fr }
  tt.source_build_phase.add_file_reference(fr)
end

p.save
puts "Stage08CannyTests.swift added to #{TEST_TARGET}"
```

Run it:

```bash
ruby /tmp/phase1b-add-canny-test.rb
```

Expected: `Stage08CannyTests.swift added to eva-swift-stitchTests`.

- [ ] **Step 4: Run the test bundle**

```
mcp__XcodeBuildMCP__test_device
```

Expected: `Test Succeeded` — 125 passed / 0 failed. The Canny test moved from `CameraKitTests.Stage08Tests` (dual-membered, count: 1 test) to `eva-swift-stitchTests.Stage08CannyTests` (single-membered, count: 1 test); net 0 change in test count. The dual-membered Stage08Tests now has 6 tests there (down from 7).

If the build fails at `Stage08CannyTests.swift` with "Cannot find type CppCannyStub":
- Verify `eva-swift-stitch.app` (the host) compiled it. The test target inherits the host's bridging header when host-app testing is active.
- Cross-check `TEST_HOST = $(BUILT_PRODUCTS_DIR)/eva-swift-stitch.app/eva-swift-stitch` is set on the test target's configs (it already is per Phase 1A).
- If still failing, the test target may need its own `SWIFT_OBJC_BRIDGING_HEADER` set to the same path as the app — set it via a small gem patch and rerun.

- [ ] **Step 5: Commit Tasks 8 + 9 together**

```bash
git add eva-swift-stitch.xcodeproj/project.pbxproj \
        CameraKit/Tests/CameraKitTests/Stage08Tests.swift \
        eva-swift-stitchTests/Stage08CannyTests.swift
git commit -m "test(phase-1b): relocate Canny test to app target; drop interop dep from app

- Stage08Tests.cannyStubConsumerReceivesTrackerFrames -> Stage08CannyTests
  (single-membership: depends on app-target CppCannyStub)
- Drop CameraKitInterop product dep from app target (no longer imported)
- Test target keeps CameraKitInterop dep for CppCaptureAtomic
- Full bundle: 125 / 0 / 0"
```

---

## Task 10: Add the C-ABI parity probe test

**Files:**
- Create: `eva-swift-stitchTests/CABIParityTests.swift`
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (via gem)

Per spec §1B: "1B adds a minimal non-OpenCV C consumer (counts frames, no image processing) registered via the **C-ABI** path (`pixel_sink_pool_register`), plus a test asserting it observes the same frame sequence as a Swift-API consumer on the same stream." The C++ counter consumer already exists (Task 4); this task writes the Swift test that exercises it.

- [ ] **Step 1: Write the parity test**

Create `eva-swift-stitchTests/CABIParityTests.swift`:

```swift
// CABIParityTests — Phase 1B C-ABI parity probe.
// Exercises pixel_sink_pool_register (raw C-ABI) on the same pool as
// engine.consumers.registerCallback (Swift API) and asserts identical
// frame sequences. This is the path Phase 3's Flutter plugin native code
// will use; without this probe it ships unexercised until Phase 3, where
// divergences (context lifetime, threading, counters) are hardest to debug.
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CameraKit
import CameraKitInterop   // for CppPixelSinkPool — to mint a pool standalone

@Suite("Phase-1B C-ABI parity", .progressLogged)
struct CABIParityTests {

    private func makeSyntheticFrameSet(frameNumber: UInt64) throws -> FrameSet {
        let width = 64
        let height = 48
        func makeBuffer() throws -> CVPixelBuffer {
            var buf: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let status = CVPixelBufferCreate(
                nil, width, height,
                kCVPixelFormatType_64RGBAHalf,
                attrs as CFDictionary, &buf)
            guard status == kCVReturnSuccess, let b = buf else {
                throw NSError(domain: "test", code: Int(status))
            }
            return b
        }
        return FrameSet(
            frameNumber: frameNumber,
            captureTime: CMTime(value: 1000, timescale: 1_000_000_000),
            natural: try makeBuffer(),
            processed: try makeBuffer(),
            tracker: try makeBuffer(),
            capture: .placeholder(),
            processing: ProcessingMetadata(
                color: ColorUniform(.identity),
                crop: CropUniform.full(width: width, height: height)),
            blurScore: 0,
            trackerQuality: .good
        )
    }

    /// A C-ABI-registered consumer and a Swift-API-registered consumer on the
    /// same stream observe identical frame numbers when yield() is called.
    @Test("1b:c-abi-parity-with-swift-api")
    func cabiParityWithSwiftAPI() async throws {
        let registry = ConsumerRegistry()

        // Get the raw pool pointer. registry.nativePipelinePointer() returns
        // UInt64 (uintptr_t of the pool); CounterConsumer takes void*.
        let rawPool = UnsafeMutableRawPointer(bitPattern: UInt(registry.nativePipelinePointer()))!

        // --- C-ABI consumer (counter, via pixel_sink_pool_register) ---
        let counter = counter_consumer_create()!
        let cAbiToken = counter_consumer_register(counter, rawPool, StreamId.tracker.rawPoolId)
        #expect(cAbiToken != 0, "Counter registration via C-ABI rejected (token 0)")

        // --- Swift API consumer (also counting, via registerCallback) ---
        let swiftCounter = LockingCounter()
        let swiftLast = LockingLastFrame()
        let swiftCbs = PixelSinkCallbacks(
            onFrame: { ctx, _, frameNumber, _, _ in
                let pair = Unmanaged<CounterPair>.fromOpaque(ctx!).takeUnretainedValue()
                pair.counter.increment()
                pair.last.set(frameNumber)
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(CounterPair(counter: swiftCounter, last: swiftLast)).toOpaque()
        )
        let swiftToken = try await registry.registerCallback(stream: .tracker, callbacks: swiftCbs)

        // --- Drive 20 frames ---
        for i: UInt64 in 1...20 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }

        // --- Assert parity ---
        let cAbiFrameCount = counter_consumer_frame_count(counter)
        let cAbiLastFrame = counter_consumer_last_frame_number(counter)
        #expect(cAbiFrameCount == 20, "C-ABI counter saw \(cAbiFrameCount) frames, expected 20")
        #expect(cAbiLastFrame == 20, "C-ABI counter's last frame is \(cAbiLastFrame), expected 20")
        #expect(swiftCounter.value == 20, "Swift counter saw \(swiftCounter.value) frames, expected 20")
        #expect(swiftLast.value == 20, "Swift counter's last frame is \(swiftLast.value), expected 20")

        // Cleanup
        counter_consumer_unregister(counter, rawPool, cAbiToken)
        counter_consumer_destroy(counter)
        await registry.unregister(token: swiftToken)
    }

    /// Register → unregister cycle leaks nothing observable: a second register
    /// with a fresh counter still sees frames; the first counter's count freezes.
    @Test("1b:c-abi-unregister-stops-delivery")
    func cabiUnregisterStopsDelivery() async throws {
        let registry = ConsumerRegistry()
        let rawPool = UnsafeMutableRawPointer(bitPattern: UInt(registry.nativePipelinePointer()))!

        let counter1 = counter_consumer_create()!
        let token1 = counter_consumer_register(counter1, rawPool, StreamId.tracker.rawPoolId)
        #expect(token1 != 0)

        for i: UInt64 in 1...5 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter_consumer_frame_count(counter1) == 5)

        counter_consumer_unregister(counter1, rawPool, token1)

        // Second 5 frames go to no consumer for now
        for i: UInt64 in 6...10 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter_consumer_frame_count(counter1) == 5,
                "Unregistered counter must not receive further frames")

        // Re-register with a fresh counter; observes only future frames
        let counter2 = counter_consumer_create()!
        let token2 = counter_consumer_register(counter2, rawPool, StreamId.tracker.rawPoolId)
        #expect(token2 != 0)
        for i: UInt64 in 11...15 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter_consumer_frame_count(counter2) == 5)
        #expect(counter_consumer_last_frame_number(counter2) == 15)

        counter_consumer_unregister(counter2, rawPool, token2)
        counter_consumer_destroy(counter1)
        counter_consumer_destroy(counter2)
    }
}

// MARK: - Test helpers

private final class LockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private final class LockingLastFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64 = 0
    func set(_ v: UInt64) { lock.withLock { _value = v } }
    var value: UInt64 { lock.withLock { _value } }
}

private final class CounterPair {
    let counter: LockingCounter
    let last: LockingLastFrame
    init(counter: LockingCounter, last: LockingLastFrame) {
        self.counter = counter
        self.last = last
    }
}
```

Note on `registry.nativePipelinePointer()`: this method exists per the `CameraEngine.swift` code (line 286: `let poolPtr = consumers.nativePipelinePointer()`). It returns a `UInt64` (the pool's `uintptr_t`). Use `UnsafeMutableRawPointer(bitPattern: UInt(...))` to convert for the C-ABI.

If `nativePipelinePointer()` turns out to be **internal** (not public on `ConsumerRegistry`), check via `scripts/dump-interface.sh` and `/tmp/CameraKit.swiftinterface`. If internal, either: (a) the test relies on `@testable import CameraKit` and that grants internal access — which it does for things in the `CameraKit` module — so it should work; or (b) promote it to `public` in a tiny prep edit.

- [ ] **Step 2: Add the test file to the test target via the gem**

Create `/tmp/phase1b-add-parity-test.rb`:

```ruby
require 'xcodeproj'

PROJECT = 'eva-swift-stitch.xcodeproj'
TEST_TARGET = 'eva-swift-stitchTests'

p = Xcodeproj::Project.open(PROJECT)
tt = p.targets.find { |t| t.name == TEST_TARGET } or abort "test target not found"

tests_grp = p.main_group['eva-swift-stitchTests'] || p.main_group.new_group(TEST_TARGET, TEST_TARGET)

fr = tests_grp.files.find { |f| f.path == 'CABIParityTests.swift' }
unless fr
  fr = tests_grp.new_file('CABIParityTests.swift')
  fr.last_known_file_type = 'sourcecode.swift'
end

unless tt.source_build_phase.files.any? { |bf| bf.file_ref == fr }
  tt.source_build_phase.add_file_reference(fr)
end

p.save
puts "CABIParityTests.swift added to #{TEST_TARGET}"
```

Run:

```bash
ruby /tmp/phase1b-add-parity-test.rb
```

- [ ] **Step 3: Run the test bundle**

```
mcp__XcodeBuildMCP__test_device
```

Expected: `Test Succeeded` — 127 passed / 0 failed (125 baseline + 2 new parity tests).

Filter to just the new tests during iteration:

```
mcp__XcodeBuildMCP__test_device  
  extraArgs: -only-testing:eva-swift-stitchTests/CABIParityTests
```

- [ ] **Step 4: Commit**

```bash
git add eva-swift-stitchTests/CABIParityTests.swift \
        eva-swift-stitch.xcodeproj/project.pbxproj
git commit -m "test(phase-1b): add C-ABI parity probe (CounterConsumer via pixel_sink_pool_register)

- pixel_sink_pool_register path observes same frame sequence as Swift API
- register/unregister cycle leaks no observable delivery
- Full bundle: 127 / 0 / 0"
```

---

## Task 11: Remove `opencv2` from `Package.swift` (final decoupling)

**Files:**
- Modify: `CameraKit/Package.swift`
- Modify: `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h` (drop the `canny_stub_*` declarations)

Until now the package still pretends to need OpenCV: the `binaryTarget` is declared and `CameraKitCxx` lists it as a dependency. With the Canny source gone from `CameraKitCxx` (Task 3), the dependency is dead. Removing it is the Phase 1B exit step — the moment `CameraKit` becomes OpenCV-free.

- [ ] **Step 1: Remove the `canny_stub_*` declarations from the package header**

Edit `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h`. Delete the entire `// MARK: - CannyStubConsumer C-ABI (canny_stub_*)` section and the five `void*    canny_stub_create(void);` lines below it (current lines 58–65).

Verify:

```bash
grep -n "canny_stub\|CannyStub" CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h CameraKit/Sources/CameraKitCxx/include/module.modulemap
```

Expected: 0 hits in either file.

- [ ] **Step 2: Remove `opencv2` from `Package.swift`**

Open `CameraKit/Package.swift`. Make two changes:

**(a)** Delete the `opencv2` `binaryTarget` block:

```swift
        // OpenCV v4.13 xcframework for Canny edge detection (ADR-29).
        // Path is relative to CameraKit/Package.swift.
        // Only ios-arm64 slice present; sufficient for physical iPad + Mac "Designed for iPad".
        .binaryTarget(
            name: "opencv2",
            path: "../Frameworks/opencv2.xcframework"
        ),
```

**(b)** Update `CameraKitCxx`:
- Remove `"opencv2"` from `dependencies`
- Update the comment to reflect the new role

The resulting `CameraKitCxx` target block:

```swift
        // C++ PixelSink pool + atomics. No OpenCV — Phase 1B (2026-05-15) moved
        // the Canny consumer + the opencv2 xcframework into the eva-swift-stitch
        // app target. The package now contains the consumer-join seam only
        // (PixelSinkPool fan-out, CaptureAtomic capture guard); external code
        // joins via engine.getNativePipelineHandle() + pixel_sink_pool_register.
        .target(
            name: "CameraKitCxx",
            dependencies: [],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("CPP_POOL_THREAD_COUNT", to: "4"),
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
```

(Note: the package's CoreFoundation linkage stays — `CaptureAtomic.cpp` doesn't need it but it's harmless and was added in Phase 1A. Don't strip it.)

- [ ] **Step 3: Build the package headless to confirm OpenCV is gone**

```
mcp__XcodeBuildMCP__build_device
```

Expected: `Build Succeeded`. The package's build graph no longer references `opencv2`. If the build fails with "Module 'CameraKitCxx' missing required dependency 'opencv2'" the dep is still there; re-check Step 2.

Cross-check the package is OpenCV-free with a grep over the source tree:

```bash
grep -rn "opencv\|cv::\|OpenCV" CameraKit/Sources/
```

Expected: 0 hits. The package is now truly OpenCV-free.

- [ ] **Step 4: Run the full test bundle**

```
mcp__XcodeBuildMCP__test_device
```

Expected: `Test Succeeded` — 127 / 0 / 0.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Package.swift CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h
git commit -m "feat(phase-1b): remove opencv2 from CameraKit package (final decoupling)

- Drop opencv2 binaryTarget + CameraKitCxx dependency
- Drop canny_stub_* declarations from PixelSinkCallbacks.h
- Package source tree contains zero OpenCV references; CameraKit builds
  with no opencv2 in its graph
- Full bundle: 127 / 0 / 0"
```

---

## Task 12: Verify HITL — Canny edge-count overlay on iPad

**Files:** none (HITL evidence captured in `docs/measurements/phase-1b/`)

The Phase 1A release introduced a regression risk for the DEBUG Canny overlay (`DisplayViewModel` now consumes a relocated wrapper through a relocated bridging header). Spec §Verification — Phase 1B requires: "the app links opencv2.xcframework, registers its Canny consumer through the seam after `engine.open()`, and edge counts flow on device — the Stage 08 Canny behaviour is preserved, just app-side."

- [ ] **Step 1: Confirm device is connected and configured**

```bash
xcrun xctrace list devices | grep -i ipad
```

Expected: Shreeyak's iPad Pro 11" 2nd-gen (UDID `00008027-000539EA0184402E`) listed. If a different iPad is connected, look up its xctrace UDID per CLAUDE.md §8's two-iPad note and update XcodeBuildMCP session defaults.

- [ ] **Step 2: Build + run the app on device**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: app launches on the iPad.

- [ ] **Step 3: Capture device logs and verify Canny is producing edge counts**

```bash
scripts/device-log-live.sh > /tmp/phase1b-canny-log.log &
```

In the app: tap the camera permission grant if prompted; wait for the preview to start; perform any action that exercises the tracker stream for ~10 s.

Then `kill %1` and inspect:

```bash
grep -i "canny\|appcxx\|edge" /tmp/phase1b-canny-log.log | tail -50
```

Expected output:
- A `CppCannyStub: created` line (subsystem `com.cambrian.camerakit`, category `appcxx`) at app startup
- `CannyStub` `os_log` lines from `CannyConsumer.cpp` (`frame=… stream=… edges=… total=…`) every 30 frames, with `edges` > 0 if the scene contains edges
- No `Cannot find symbol` / link errors

If the overlay (long-press toggle in `CameraView`) is enabled, screenshot the edge count via:

```
mcp__XcodeBuildMCP__screenshot
```

- [ ] **Step 4: Record HITL evidence**

```bash
mkdir -p docs/measurements/phase-1b
```

Create `docs/measurements/phase-1b/canny-overlay.md`:

```markdown
# Phase 1B — Canny edge-count overlay HITL evidence

**Date:** YYYY-MM-DD (replace with the run date)
**Device:** Shreeyak's iPad Pro 11" 2nd-gen, iOS 26.x, UDID 00008027-000539EA0184402E
**Build:** scheme `eva-swift-stitch`, Debug, via XcodeBuildMCP `build_run_device`

**Result:** PASS — Canny consumer registered through the app-target AppCxx
path after `engine.open()`; edge counts non-zero on a textured scene; debug
overlay (long-press toggle) shows live edge counts.

**Log excerpt (verbatim, from /tmp/phase1b-canny-log.log):**

```
<paste 5-10 lines of CannyStub os_log output here>
```

**Notes:** Spec §Verification — Phase 1B "edge counts flow on device" — verified.
The Stage 08 Canny behaviour is preserved, just app-side.
```

No commit on the screenshot; commit the markdown.

```bash
git add docs/measurements/phase-1b/canny-overlay.md
git commit -m "docs(phase-1b): HITL evidence — Canny overlay still firing on iPad"
```

---

## Task 13: Regenerate CONTRACTS.md + update state.md + DECISIONS.md

**Files:**
- Modify: `CameraKit/CONTRACTS.md` (auto-regenerated)
- Modify: `CameraKit/state.md` (Phase 1B landing record)
- Modify: `CameraKit/DECISIONS.md` (append the decision entry)

- [ ] **Step 1: Regenerate CONTRACTS.md**

```bash
scripts/regen-contracts.sh
```

Expected: CONTRACTS.md updated. The diff should show:
- `CppCannyStub` removed from `CameraKitInterop`'s public surface
- `canny_stub_*` C-ABI gone from `CameraKitCxx`'s public surface
- No new public symbols in `CameraKit`

Verify the diff is in those directions:

```bash
git diff CameraKit/CONTRACTS.md | grep -E "^[-+].*Canny|canny"
```

Expected: only `-` lines (removals), no `+` lines.

- [ ] **Step 2: Append a `DECISIONS.md` entry**

Append to `CameraKit/DECISIONS.md`:

```markdown
## Phase 1B (2026-05-15) — OpenCV consumer relocated app-side

**Decision:** `CannyStubConsumer.cpp` (the only OpenCV user in the package)
moved to `eva-swift-stitch/AppCxx/CannyConsumer.cpp`. The `opencv2`
`binaryTarget` and `CameraKitCxx → opencv2` dependency removed from
`Package.swift`. `CppCannyStub` Swift wrapper moved from
`CameraKitInterop/CameraKitInterop.swift` to
`eva-swift-stitch/AppCxx/CppCannyStub.swift`. App target gains an
Objective-C bridging header (`AppCxx/AppCxx-Bridging-Header.h`) exposing
the new `canny_stub_*` + `counter_consumer_*` C-ABIs.

**On the move, `CannyStubConsumer` dropped its `: public PixelSink`
inheritance.** The C-ABI thunk `canny_stub_on_frame` was the only caller
of the virtual `onFrame(PixelFrame)`; dropping the inheritance eliminated
the `PixelSink.hpp` + `PixelFrame` header dependency, making the
relocation a true byte-move with no header search path back into the
package needed for `CannyConsumer.cpp` itself (`CounterConsumer.cpp`
still needs one for the C-ABI declarations in `<PixelSinkCallbacks.h>`).

**`CameraKitInterop` product stays exported.** The Phase 1A landing memo
predicted Phase 1B would un-export it; that proved over-optimistic. The
dual-membered `Stage08Tests.stillCaptureUsesCppAtomic` imports
`CppCaptureAtomic` from `CameraKitInterop` and runs in the Xcode test
target; un-exporting would break it. App target drops the dep; test
target keeps it. CLAUDE.md §8's dual-membership default stays intact.

**C-ABI parity probe added.** `eva-swift-stitch/AppCxx/CounterConsumer.cpp`
+ `eva-swift-stitchTests/CABIParityTests.swift`. The C-ABI path
(`pixel_sink_pool_register` against `engine.getNativePipelineHandle()`)
and the Swift API (`engine.consumers.registerCallback`) observe identical
frame sequences. This is what Phase 3's Flutter plugin native code will
use; previously it was completely unexercised.

**Files relocated app-side (no longer in package):**
- `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp`
  → `eva-swift-stitch/AppCxx/CannyConsumer.cpp`
- `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift` (CppCannyStub section)
  → `eva-swift-stitch/AppCxx/CppCannyStub.swift`
- `CameraKit/Tests/CameraKitTests/Stage08Tests.cannyStubConsumerReceivesTrackerFrames`
  → `eva-swift-stitchTests/Stage08CannyTests.swift`

**Files added app-side:**
- `eva-swift-stitch/AppCxx/CounterConsumer.cpp` + `include/CounterConsumer.h`
- `eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h`
- `eva-swift-stitch/AppCxx/include/CannyConsumer.h`
- `eva-swift-stitchTests/CABIParityTests.swift`

**xcodeproj changes (via Ruby `xcodeproj` gem):**
- App target: `SWIFT_OBJC_BRIDGING_HEADER`, `HEADER_SEARCH_PATHS`
  (`$(SRCROOT)/CameraKit/Sources/CameraKitCxx/include`),
  `FRAMEWORK_SEARCH_PATHS` (`$(SRCROOT)/Frameworks`),
  `opencv2.xcframework` linked + embed-signed
- App target drops the `CameraKitInterop` `XCSwiftPackageProductDependency`
- Test target adds `Stage08CannyTests.swift` + `CABIParityTests.swift`
  (single-target membership, deliberate exception to CLAUDE.md §8 default —
  same precedent as Phase 1A's `Stage11UITests.swift`)

**Phase 1B exit gate:** `grep -rn "opencv\|cv::\|OpenCV" CameraKit/Sources/` → 0 hits.
**Test bundle:** 127 passed / 0 failed (125 prior baseline + 2 new parity probes).
**HITL:** edge-count overlay still firing on iPad — `docs/measurements/phase-1b/canny-overlay.md`.
```

- [ ] **Step 3: Replace the Phase 1A landing section in state.md with Phase 1B**

Open `CameraKit/state.md`. The current top section is `# state.md — Migration Phase 1A (post-Stage-12)`. Replace it (keep everything from `---\n\n# state.md — Stage 12 (historical)` onward intact).

The new top section:

```markdown
# state.md — Migration Phase 1B (post-Phase-1A)

## Current stage

Phase 1B complete (Flutter migration — OpenCV consumer decoupling).
CameraKit package now contains **zero OpenCV references**; `opencv2.xcframework`
relocated to `eva-swift-stitch/AppCxx/` app target. `CannyStubConsumer.cpp`
→ `eva-swift-stitch/AppCxx/CannyConsumer.cpp` (with `PixelSink` inheritance
dropped — the C-ABI thunk was the only caller, the inheritance was dead).
`CppCannyStub` Swift wrapper → `eva-swift-stitch/AppCxx/CppCannyStub.swift`.
App target gains `AppCxx-Bridging-Header.h` exposing the relocated `canny_stub_*`
C-ABI + the new `counter_consumer_*` C-ABI (parity probe).

Full test bundle: **127 passed / 0 failed** on Shreeyak's iPad
(UDID `00008027-000539EA0184402E`, iOS 26.x), scheme `eva-swift-stitch`,
via `mcp__XcodeBuildMCP__test_device` — 125 prior baseline + 2 new parity
probes (`CABIParityTests.cabiParityWithSwiftAPI`,
`CABIParityTests.cabiUnregisterStopsDelivery`).

C-ABI parity verified: a `pixel_sink_pool_register`-registered C consumer and
a Swift-API `registerCallback`-registered consumer on the same stream observe
identical frame sequences. This is the path Phase 3's Flutter plugin native
code will use.

HITL: Canny edge-count overlay still firing on iPad after `engine.open()` —
`docs/measurements/phase-1b/canny-overlay.md`.

Bridge state: `CameraKitInterop` **stays exported** as a SwiftPM product.
The dual-membered `Stage08Tests.stillCaptureUsesCppAtomic` still imports
`CppCaptureAtomic` from it. The Phase 1A memo's "Phase 1B unexports this"
prediction was over-optimistic; un-exporting would break that test in the
Xcode test target. App target dropped its `CameraKitInterop` dep; test target
keeps it. CLAUDE.md §8 dual-membership default stays intact.

Public-surface changes (Phase 1B):
- Removed from `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h`:
  `canny_stub_create`, `canny_stub_destroy`, `canny_stub_on_frame`,
  `canny_stub_processed_count`, `canny_stub_edge_count` (relocated app-side)
- Removed from `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift`:
  `public final class CppCannyStub` (relocated app-side)
- No public additions to `CameraKit` itself.

## Scaffolding still live

_None._ Phase 1B added no scaffolds; the post-Stage-12 empty scaffold corpus
is preserved.

---

```

(Then the existing `# state.md — Migration Phase 1A` and `# state.md — Stage 12 (historical)` sections follow, demoted to historical.)

Actually — keep both as historical: move the existing Phase 1A header from `# state.md — Migration Phase 1A (post-Stage-12)` to `# state.md — Migration Phase 1A (historical)` to mark the change.

```bash
# Quick verification after editing
grep -n "^# state.md" CameraKit/state.md
```

Expected:
- `# state.md — Migration Phase 1B (post-Phase-1A)`
- `# state.md — Migration Phase 1A (historical)`
- `# state.md — Stage 12 (historical)`

- [ ] **Step 4: Final verification**

```
mcp__XcodeBuildMCP__test_device
```

Expected: 127 / 0 / 0.

```bash
scripts/scaffold-inventory.sh
```

Expected: empty scaffold inventory (unchanged from Phase 1A / Stage 12).

```bash
grep -rn "opencv\|cv::\|OpenCV" CameraKit/Sources/
```

Expected: 0 hits. The Phase 1B exit gate.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/CONTRACTS.md CameraKit/state.md CameraKit/DECISIONS.md
git commit -m "docs(phase-1b): record OpenCV consumer decoupling landing

- CONTRACTS.md regenerated (CppCannyStub, canny_stub_* removed from package surface)
- state.md: Phase 1B landing record (Phase 1A demoted to historical)
- DECISIONS.md: rationale for relocation, inheritance drop, product-export decision
- Phase 1B exit: grep -rn 'opencv' CameraKit/Sources/ -> 0 hits
- Full bundle: 127 / 0 / 0"
```

---

## Phase 1B exit criteria (verify before declaring done)

- [ ] `grep -rn "opencv\|cv::\|OpenCV" CameraKit/Sources/` → 0 hits
- [ ] `grep -rn "canny_stub\|CppCannyStub\|CannyStub" CameraKit/Sources/` → 0 hits
- [ ] `CameraKit/Package.swift` contains no `binaryTarget(name: "opencv2", …)` and no `"opencv2"` in any target's `dependencies`
- [ ] App target's `eva-swift-stitch.xcodeproj` links `Frameworks/opencv2.xcframework` (and embeds it with code-signing)
- [ ] App target's `eva-swift-stitch.xcodeproj` no longer has `CameraKitInterop` in its `packageProductDependencies`
- [ ] Test target keeps `CameraKitInterop` in its `packageProductDependencies` (for `Stage08Tests.stillCaptureUsesCppAtomic`)
- [ ] `mcp__XcodeBuildMCP__test_device` → 127 / 0 / 0 on Shreeyak's iPad
- [ ] CABI parity probe (`CABIParityTests.cabiParityWithSwiftAPI`) passes
- [ ] HITL: Canny edge-count overlay still firing on iPad after `engine.open()`; evidence in `docs/measurements/phase-1b/canny-overlay.md`
- [ ] `CONTRACTS.md` regenerated; `state.md` records Phase 1B landing; `DECISIONS.md` has the new entry

---

## Notes for the executor

- **Verification before completion** (CLAUDE.md, superpowers): every test/build claim in this plan must be backed by the actual command output. Don't paste expected values; run the commands and quote what you see.
- **Never `*_sim` variants** of XcodeBuildMCP tools (CLAUDE.md §6 hard rule). Physical iPad → Mac "Designed for iPad" → error. Simulators are disallowed on this machine.
- **xcodeproj mutations through the Ruby gem only.** Never hand-edit `project.pbxproj`. The CLAUDE.md §8 gotcha about SPM products needing `product_ref` (not `fileRef`) is relevant to Task 8.
- **`scripts/sync-test-target.sh` does not manage `eva-swift-stitchTests/`** — it syncs `CameraKit/Tests/CameraKitTests/` into the Xcode test target. New files under `eva-swift-stitchTests/` go in via the gem (Tasks 9 + 10).
- **If `mcp__XcodeBuildMCP__test_device` build cache goes weird** (e.g. SourceKit phantom errors after target changes, per CLAUDE.md §6 Build-log-is-ground-truth rule): `rm -rf ~/Library/Developer/Xcode/DerivedData/eva-swift-stitch-*` and rebuild.
- **Don't commit `/tmp/phase1b-*.rb` scripts.** They are throwaways. If reuse is needed, they can be archived to `docs/superpowers/plans/2026-05-15-phase-1b-scripts/` later.
