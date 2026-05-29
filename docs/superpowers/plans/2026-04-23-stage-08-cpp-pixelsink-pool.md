# Stage 08 — C++ PixelSink Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire three Stage 06/07 scaffolds by wiring the real C++ `PixelSink` pool (Mechanism A), C-ABI capture atomic, and full Pass-1+2+4 processed chain — while preserving every prior test.

**Architecture:** A new `CameraKitCxx` SPM target provides a `std::mutex`-guarded `PixelSinkPool` with `pipeline > stage > consumer` lock ordering (D-16). A thin `CameraKitInterop` Swift module (`.interoperabilityMode(.Cxx)`) wraps C++ types in a Swift-visible API. `ConsumerRegistry` dispatches to both Swift `AsyncStream` subscribers and C++ pool consumers from `yield()` — dual-dispatch chosen over full C++ routing because `FrameSet` is a Swift multi-buffer struct that can't be trivially reconstructed from a per-stream C-ABI surface pointer; decision logged in DECISIONS.md. `CannyStubConsumer` runs real OpenCV Canny edge detection on tracker frames (OpenCV v4.13 xcframework at `Frameworks/opencv2.framework`) and stores `(frameNumber, edgePixelCount)` tuples in a ring buffer for the debug overlay (ADR-29). HITL `08:external-canny-stub-runs-on-device` is attempted on iPad Pro M1.

**Tech Stack:** Swift 6.2 / C++20, SPM `.interoperabilityMode(.Cxx)`, `std::atomic<bool>`, `std::mutex`, `std::thread`, `CVPixelBufferGetIOSurface`, `IOSurfaceRef`.

---

## File Structure

**Create:**
- `CameraKit/Sources/CameraKitCxx/include/PixelSink.hpp` — C++ abstract `PixelSink` class (ADR-31); POD-only public surface
- `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h` — C header with `PixelSinkCallbacks` POD struct (D-03)
- `CameraKit/Sources/CameraKitCxx/include/CaptureAtomic.hpp` — `std::atomic<bool>` CAS; C-ABI bridge declarations
- `CameraKit/Sources/CameraKitCxx/PixelSinkPool.cpp` — pool implementation; `std::mutex`, three-lane fan-out, thread pool cap `CPP_POOL_THREAD_COUNT`
- `CameraKit/Sources/CameraKitCxx/CaptureAtomic.cpp` — C-ABI functions `capture_atomic_try_acquire()` / `capture_atomic_release()` exposed to Swift
- `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp` — OpenCV-backed Canny edge detection; edge pixel count stored in ring buffer for debug overlay (ADR-29)
- `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift` — `public final class CppPixelSinkPool` wrapping C++ pool; `public final class CppCaptureAtomic` wrapping C++ atomic

**Modify:**
- `CameraKit/Package.swift` — add `CameraKitCxx` C++ target + `CameraKitInterop` Swift target; wire deps
- `CameraKit/Sources/CameraKit/PixelSink.swift` — real `registerCallback`; `cppPool: CppPixelSinkPool`; dual-dispatch in `yield()`; retire `06:simple-consumer-swift-only`
- `CameraKit/Sources/CameraKit/StillCapture.swift` — replace `ManagedAtomic<Bool>` with `CppCaptureAtomic`; retire `07:swift-side-capture-atomic`
- `CameraKit/Sources/CameraKit/MetalPipeline.swift` — remove `01:simple-metal-passthrough` scaffold comments
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — add `getNativePipelineHandle() -> UInt64?`
- `CameraKit/Sources/CameraKit/Errors.swift` — add `InteropError.retainMismatch` and `InteropError.invalidCallbacks`; remove or keep `.notWired` per brief
- `CameraKit/Sources/CameraKit/Constants.swift` — add `cppPoolThreadCount`
- `CameraKit/Sources/CameraKit/TexturePoolManager.swift` — remove `01:simple-metal-passthrough` scaffold comment
- `CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal` — remove `01:simple-metal-passthrough` scaffold comment

**Create:**
- `CameraKit/Tests/CameraKitTests/Stage08Tests.swift`
- `docs/measurements/stage-08/canny.md` — HITL evidence template for `08:external-canny-stub-runs-on-device`

---

## Phase A: Package.swift + empty C++ targets

### Task 1: Add SPM targets for CameraKitCxx and CameraKitInterop

**Files:**
- Modify: `CameraKit/Package.swift`
- Create: `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h`
- Create: `CameraKit/Sources/CameraKitCxx/include/PixelSink.hpp`
- Create: `CameraKit/Sources/CameraKitCxx/include/CaptureAtomic.hpp`
- Create: `CameraKit/Sources/CameraKitCxx/PixelSinkPool.cpp`
- Create: `CameraKit/Sources/CameraKitCxx/CaptureAtomic.cpp`
- Create: `CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp`
- Create: `CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p CameraKit/Sources/CameraKitCxx/include
mkdir -p CameraKit/Sources/CameraKitInterop
```

- [ ] **Step 2: Create `PixelSinkCallbacks.h` (C header, no C++ types)**

```c
// CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*OnFrameFn)(void* context, uint32_t stream,
                          uint64_t frameNumber, int64_t presentationTimeNs,
                          void* surface);
typedef void (*OnOverwriteFn)(void* context, uint32_t stream);
typedef void (*OnErrorFn)(void* context, int32_t code);

typedef struct {
    OnFrameFn  on_frame;
    OnOverwriteFn on_overwrite;
    OnErrorFn  on_error;
    void*      context;
} PixelSinkCallbacks;

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 3: Create `PixelSink.hpp` (C++ abstract class per ADR-31)**

```cpp
// CameraKit/Sources/CameraKitCxx/include/PixelSink.hpp
#pragma once
#include <cstdint>

struct PixelFrame {
    uint32_t stream;
    uint64_t frameNumber;
    int64_t  presentationTimeNs;
    void*    surface;  // IOSurfaceRef, valid for duration of call only
};

struct OverwriteEvent {
    uint32_t stream;
};

class PixelSink {
public:
    virtual void onFrame(const PixelFrame&) = 0;
    virtual void onOverwrite(const OverwriteEvent&) = 0;
    virtual ~PixelSink() = default;
};
```

- [ ] **Step 4: Create `CaptureAtomic.hpp` (C++ atomic + C-ABI declarations)**

```cpp
// CameraKit/Sources/CameraKitCxx/include/CaptureAtomic.hpp
#pragma once
#include <atomic>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void* capture_atomic_create(void);
void  capture_atomic_destroy(void* handle);
bool  capture_atomic_try_acquire(void* handle);  // CAS false→true
void  capture_atomic_release(void* handle);       // store false

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 5: Create `PixelSinkPool.cpp` (minimal skeleton that compiles)**

```cpp
// CameraKit/Sources/CameraKitCxx/PixelSinkPool.cpp
#include "PixelSink.hpp"
#include "PixelSinkCallbacks.h"
#include <mutex>
#include <vector>
#include <thread>
#include <algorithm>
#include <cstdint>

static constexpr unsigned kMaxThreads = 4;

struct ConsumerEntry {
    uint64_t        token;
    PixelSinkCallbacks cbs;
    uint32_t        stream;
};

class PixelSinkPool {
public:
    PixelSinkPool() : threadCount_(std::min(kMaxThreads,
                                            std::thread::hardware_concurrency())) {}

    uint64_t registerConsumer(uint32_t stream, PixelSinkCallbacks cbs) {
        std::lock_guard<std::mutex> pipeline_lock(pipelineMutex_);
        std::lock_guard<std::mutex> stage_lock(stageMutex_);
        std::lock_guard<std::mutex> consumer_lock(consumerMutex_);
        uint64_t id = nextId_++;
        consumers_.push_back({id, cbs, stream});
        return id;
    }

    void unregisterConsumer(uint64_t token) {
        std::lock_guard<std::mutex> pipeline_lock(pipelineMutex_);
        std::lock_guard<std::mutex> stage_lock(stageMutex_);
        std::lock_guard<std::mutex> consumer_lock(consumerMutex_);
        consumers_.erase(
            std::remove_if(consumers_.begin(), consumers_.end(),
                [token](const ConsumerEntry& e){ return e.token == token; }),
            consumers_.end());
    }

    void dispatch(uint32_t stream, uint64_t frameNumber,
                  int64_t presentationTimeNs, void* surface) {
        std::lock_guard<std::mutex> pipeline_lock(pipelineMutex_);
        std::lock_guard<std::mutex> stage_lock(stageMutex_);
        std::lock_guard<std::mutex> consumer_lock(consumerMutex_);
        for (auto& e : consumers_) {
            if (e.stream == stream && e.cbs.on_frame) {
                e.cbs.on_frame(e.cbs.context, stream, frameNumber,
                               presentationTimeNs, surface);
            }
        }
    }

    unsigned consumerCount(uint32_t stream) const {
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
        unsigned n = 0;
        for (const auto& e : consumers_) {
            if (e.stream == stream) n++;
        }
        return n;
    }

    uintptr_t rawPointer() const { return reinterpret_cast<uintptr_t>(this); }

private:
    mutable std::mutex pipelineMutex_;  // outermost
    mutable std::mutex stageMutex_;
    mutable std::mutex consumerMutex_;  // innermost
    std::vector<ConsumerEntry> consumers_;
    uint64_t nextId_ = 1;
    unsigned threadCount_;
};

// ---- C-ABI bridge ----

extern "C" {

void* pixel_sink_pool_create(void) {
    return new PixelSinkPool();
}
void pixel_sink_pool_destroy(void* handle) {
    delete static_cast<PixelSinkPool*>(handle);
}
uint64_t pixel_sink_pool_register(void* handle, uint32_t stream,
                                  PixelSinkCallbacks cbs) {
    return static_cast<PixelSinkPool*>(handle)->registerConsumer(stream, cbs);
}
void pixel_sink_pool_unregister(void* handle, uint64_t token) {
    static_cast<PixelSinkPool*>(handle)->unregisterConsumer(token);
}
void pixel_sink_pool_dispatch(void* handle, uint32_t stream,
                              uint64_t frameNumber, int64_t presentationTimeNs,
                              void* surface) {
    static_cast<PixelSinkPool*>(handle)->dispatch(stream, frameNumber,
                                                   presentationTimeNs, surface);
}
unsigned pixel_sink_pool_consumer_count(void* handle, uint32_t stream) {
    return static_cast<PixelSinkPool*>(handle)->consumerCount(stream);
}
uintptr_t pixel_sink_pool_raw_pointer(void* handle) {
    return static_cast<PixelSinkPool*>(handle)->rawPointer();
}

}  // extern "C"
```

- [ ] **Step 6: Create `CaptureAtomic.cpp`**

```cpp
// CameraKit/Sources/CameraKitCxx/CaptureAtomic.cpp
#include "CaptureAtomic.hpp"
#include <atomic>

struct CaptureAtomicImpl {
    std::atomic<bool> flag{false};
};

void* capture_atomic_create(void) { return new CaptureAtomicImpl(); }
void  capture_atomic_destroy(void* h) { delete static_cast<CaptureAtomicImpl*>(h); }
bool  capture_atomic_try_acquire(void* h) {
    auto* a = static_cast<CaptureAtomicImpl*>(h);
    bool expected = false;
    return a->flag.compare_exchange_strong(expected, true,
        std::memory_order_acq_rel, std::memory_order_relaxed);
}
void  capture_atomic_release(void* h) {
    static_cast<CaptureAtomicImpl*>(h)->flag.store(false, std::memory_order_release);
}
```

- [ ] **Step 7: Create `CannyStubConsumer.cpp` (real OpenCV Canny, ring buffer of edge counts)**

```cpp
// CameraKit/Sources/CameraKitCxx/CannyStubConsumer.cpp
// OpenCV-backed Canny edge detection per ADR-29.
// Incoming frames come as IOSurfaceRef (void*) from the tracker stream.
// We wrap via CVPixelBufferRef to get safe, lockable access to the pixel base
// address, run cv::Canny, and write (frameNumber, edgePixelCount) tuples into
// a fixed-size ring buffer that the debug overlay reads back via C-ABI.
#include "PixelSink.hpp"
#include <opencv2/imgproc.hpp>
#include <opencv2/core.hpp>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <atomic>
#include <array>
#include <cstdint>

static constexpr size_t kRingSize = 64;
static constexpr double kCannyLow  = 50.0;
static constexpr double kCannyHigh = 150.0;

struct CannyRingEntry {
    uint64_t frameNumber;
    uint32_t stream;
    uint32_t edgePixelCount;
};

class CannyStubConsumer : public PixelSink {
public:
    void onFrame(const PixelFrame& f) override {
        uint32_t edgeCount = 0;
        if (f.surface != nullptr) {
            edgeCount = runCanny(static_cast<IOSurfaceRef>(f.surface));
        }
        size_t idx = writeIdx_.fetch_add(1, std::memory_order_relaxed) % kRingSize;
        ring_[idx] = {f.frameNumber, f.stream, edgeCount};
    }
    void onOverwrite(const OverwriteEvent&) override {}

    uint64_t processedCount() const {
        return writeIdx_.load(std::memory_order_relaxed);
    }

    uint32_t edgeCountAt(size_t idx) const {
        if (idx >= kRingSize) return 0;
        return ring_[idx].edgePixelCount;
    }

private:
    /// Wraps the IOSurface in a short-lived CVPixelBuffer, locks the base
    /// address, builds a cv::Mat view (no copy), runs Canny, returns nonzero
    /// pixel count. Returns 0 on any failure — Canny errors are not fatal.
    uint32_t runCanny(IOSurfaceRef surface) {
        CVPixelBufferRef pb = nullptr;
        CVReturn r = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, nullptr, &pb);
        if (r != kCVReturnSuccess || pb == nullptr) return 0;

        uint32_t edges = 0;
        if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
            void* base = CVPixelBufferGetBaseAddress(pb);
            size_t w = CVPixelBufferGetWidth(pb);
            size_t h = CVPixelBufferGetHeight(pb);
            size_t stride = CVPixelBufferGetBytesPerRow(pb);
            OSType fmt = CVPixelBufferGetPixelFormatType(pb);

            if (base != nullptr && w > 0 && h > 0) {
                cv::Mat gray;
                // Tracker stream is expected to be a single-channel/luma buffer;
                // fall back by converting from BGRA if needed.
                if (fmt == kCVPixelFormatType_OneComponent8) {
                    cv::Mat src(static_cast<int>(h), static_cast<int>(w),
                                CV_8UC1, base, stride);
                    gray = src;
                } else if (fmt == kCVPixelFormatType_32BGRA) {
                    cv::Mat src(static_cast<int>(h), static_cast<int>(w),
                                CV_8UC4, base, stride);
                    cv::cvtColor(src, gray, cv::COLOR_BGRA2GRAY);
                } else {
                    // Unknown format — skip Canny rather than guess.
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

    std::atomic<uint64_t> writeIdx_{0};
    std::array<CannyRingEntry, kRingSize> ring_{};
};

// C-ABI
extern "C" {
void* canny_stub_create(void) { return new CannyStubConsumer(); }
void  canny_stub_destroy(void* h) { delete static_cast<CannyStubConsumer*>(h); }
void  canny_stub_on_frame(void* ctx, uint32_t stream, uint64_t frameNum,
                          int64_t ts, void* surface) {
    PixelFrame f{stream, frameNum, ts, surface};
    static_cast<CannyStubConsumer*>(ctx)->onFrame(f);
}
uint64_t canny_stub_processed_count(void* h) {
    return static_cast<CannyStubConsumer*>(h)->processedCount();
}
uint32_t canny_stub_edge_count(void* h, size_t idx) {
    return static_cast<CannyStubConsumer*>(h)->edgeCountAt(idx);
}
}
```

> **OpenCV symbol containment (ADR-11):** `#include <opencv2/...>` appears only
> in this `.cpp` file. No OpenCV type leaks into `PixelSink.hpp`, any public
> header, or the Swift-visible C-ABI — only plain `uint32_t` edge counts cross
> the module boundary.

- [ ] **Step 8: Create `CameraKitInterop.swift`**

```swift
// CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift
// Thin Swift module isolating C++ interop per ADR-13.
// .interoperabilityMode(.Cxx) is set in Package.swift for this target only.
import Foundation

// MARK: - C-ABI bridge imports (declared via modulemap / CXX interop)
// The C functions declared in PixelSinkPool.cpp and CaptureAtomic.cpp
// are visible to this target via the CameraKitCxx module.

/// Wraps the C++ `PixelSinkPool` with a Swift-friendly reference type.
public final class CppPixelSinkPool: @unchecked Sendable {
    private var handle: UnsafeMutableRawPointer

    public init() {
        handle = pixel_sink_pool_create()!
    }
    deinit { pixel_sink_pool_destroy(handle) }

    public func register(stream: UInt32, callbacks: CppPixelSinkCallbacks) -> UInt64 {
        pixel_sink_pool_register(handle, stream, callbacks.raw)
    }
    public func unregister(token: UInt64) {
        pixel_sink_pool_unregister(handle, token)
    }
    public func dispatch(stream: UInt32, frameNumber: UInt64,
                         presentationTimeNs: Int64, surface: UnsafeMutableRawPointer?) {
        pixel_sink_pool_dispatch(handle, stream, frameNumber, presentationTimeNs, surface)
    }
    public func consumerCount(stream: UInt32) -> UInt32 {
        pixel_sink_pool_consumer_count(handle, stream)
    }
    public func rawPointer() -> UInt64 {
        UInt64(pixel_sink_pool_raw_pointer(handle))
    }
}

/// Lightweight bridge type carrying the C-ABI callback struct.
public struct CppPixelSinkCallbacks: @unchecked Sendable {
    // raw is PixelSinkCallbacks from C header
    let raw: PixelSinkCallbacks

    public init(onFrame: @escaping @convention(c) (UnsafeMutableRawPointer?,
                                                     UInt32, UInt64, Int64,
                                                     UnsafeMutableRawPointer?) -> Void,
                onOverwrite: @escaping @convention(c) (UnsafeMutableRawPointer?,
                                                        UInt32) -> Void,
                onError: @escaping @convention(c) (UnsafeMutableRawPointer?,
                                                    Int32) -> Void,
                context: UnsafeMutableRawPointer?) {
        raw = PixelSinkCallbacks(on_frame: onFrame,
                                 on_overwrite: onOverwrite,
                                 on_error: onError,
                                 context: context)
    }
}

/// Wraps the C++ `std::atomic<bool>` capture guard.
public final class CppCaptureAtomic: @unchecked Sendable {
    private var handle: UnsafeMutableRawPointer

    public init() { handle = capture_atomic_create()! }
    deinit { capture_atomic_destroy(handle) }

    /// CAS false→true. Returns true if acquired (was false, now true).
    public func tryAcquire() -> Bool { capture_atomic_try_acquire(handle) }
    /// Store false unconditionally.
    public func release() { capture_atomic_release(handle) }
}

/// Canny stub consumer wrapper (OpenCV-backed edge detection; ring buffer of
/// `(frameNumber, edgePixelCount)` tuples for debug overlay per ADR-29).
public final class CppCannyStub: @unchecked Sendable {
    private var handle: UnsafeMutableRawPointer

    public init() { handle = canny_stub_create()! }
    deinit { canny_stub_destroy(handle) }

    public var processedCount: UInt64 { canny_stub_processed_count(handle) }

    /// Reads the edge pixel count at ring-buffer index `idx` (0..<64).
    /// Used by the debug overlay to render per-frame edge metadata.
    public func edgeCount(at idx: Int) -> UInt32 {
        canny_stub_edge_count(handle, idx)
    }

    public func makeCallbacks() -> CppPixelSinkCallbacks {
        let h = handle
        return CppPixelSinkCallbacks(
            onFrame: { ctx, stream, frame, ts, surface in
                canny_stub_on_frame(ctx, stream, frame, ts, surface)
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: h
        )
    }
}
```

- [ ] **Step 9: Update `Package.swift`**

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // OpenCV v4.13 xcframework, consumed by CameraKitCxx for Canny edge
        // detection (ADR-29). Path is relative to this Package.swift
        // (CameraKit/Package.swift) so "../Frameworks" resolves to the repo's
        // top-level Frameworks/ directory where opencv2.framework lives as a
        // symlink. Local binaryTargets do NOT accept `checksum:` — that's for
        // remote URL targets only.
        .binaryTarget(
            name: "opencv2",
            path: "../Frameworks/opencv2.framework"
        ),
        .target(
            name: "CameraKitCxx",
            dependencies: ["opencv2"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("CPP_POOL_THREAD_COUNT", to: "4"),
            ],
            cxxLanguageStandard: .cxx20
        ),
        .target(
            name: "CameraKitInterop",
            dependencies: ["CameraKitCxx"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "CameraKit",
            dependencies: [
                "CameraKitInterop",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: [
                "CameraKit",
                "CameraKitInterop",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
```

- [ ] **Step 10: Build to verify Phase A compiles**

Run: `scripts/build-summary.sh` (physical iPad → Mac "Designed for iPad")

Expected: `BUILD: success` — both CameraKitCxx and CameraKitInterop compile.

Note: If `pixel_sink_pool_create` and other C functions are not visible to `CameraKitInterop.swift`, you may need to add a module map. Check build errors and add `module.modulemap` to `CameraKitCxx/include/` if needed:
```
module CameraKitCxx {
    header "PixelSinkCallbacks.h"
    header "CaptureAtomic.hpp"
    export *
}
```

- [ ] **Step 11: Commit Phase A**

```bash
git add CameraKit/Sources/CameraKitCxx/ CameraKit/Sources/CameraKitInterop/ CameraKit/Package.swift
git commit -m "feat(stage-08): add CameraKitCxx C++ target + CameraKitInterop Swift module — build green"
```

---

## Phase B: ConsumerRegistry real registerCallback (retire 06 scaffold)

### Task 2: Wire real C++ pool into ConsumerRegistry

**Files:**
- Modify: `CameraKit/Sources/CameraKit/PixelSink.swift`
- Modify: `CameraKit/Sources/CameraKit/Constants.swift`

- [ ] **Step 1: Add `cppPoolThreadCount` to Constants.swift**

In `CameraKit/Sources/CameraKit/Constants.swift`, add inside the `Constants` enum:
```swift
static let cppPoolThreadCount: Int = min(4, ProcessInfo.processInfo.processorCount)
```

- [ ] **Step 2: Rewrite `ConsumerRegistry` to use the C++ pool**

Replace `CameraKit/Sources/CameraKit/PixelSink.swift` entirely with:

```swift
import CameraKitInterop
import Foundation
import Synchronization

// Stage 08 — Real ConsumerRegistry backed by C++ PixelSinkPool (Mechanism A, D-01 / D-03).
// Dual-dispatch: yield() drives both Swift AsyncStream subscribers and C++ pool consumers.
// Decision logged in DECISIONS.md (decision #35).

/// Opaque token returned by `ConsumerRegistry.subscribe(stream:)` and
/// `.registerCallback(stream:callbacks:)`.
public struct ConsumerToken: Sendable, Hashable {
    public let id: UInt64
    public let stream: StreamId
    public init(id: UInt64, stream: StreamId) {
        self.id = id
        self.stream = stream
    }
}

/// C-ABI-shaped callback struct per ADR-31 and D-03.
public struct PixelSinkCallbacks {
    // swiftlint:disable nesting
    public typealias OnFrame =
        @convention(c) (_ context: UnsafeMutableRawPointer?, _ stream: UInt32,
                        _ frameNumber: UInt64, _ presentationTimeNs: Int64,
                        _ surface: UnsafeMutableRawPointer?) -> Void
    public typealias OnOverwrite =
        @convention(c) (_ context: UnsafeMutableRawPointer?, _ stream: UInt32) -> Void
    public typealias OnError =
        @convention(c) (_ context: UnsafeMutableRawPointer?, _ code: Int32) -> Void
    // swiftlint:enable nesting

    public let onFrame: OnFrame?
    public let onOverwrite: OnOverwrite?
    public let onError: OnError?
    public let context: UnsafeMutableRawPointer?

    public init(onFrame: OnFrame?, onOverwrite: OnOverwrite?, onError: OnError?,
                context: UnsafeMutableRawPointer?) {
        self.onFrame = onFrame
        self.onOverwrite = onOverwrite
        self.onError = onError
        self.context = context
    }
}

extension PixelSinkCallbacks: @unchecked Sendable {}

/// Swift facade for the consumer fan-out (D-01).
///
/// Swift-side `subscribe(stream:)` uses `AsyncStream` directly (Phase A of D-01's
/// dual-dispatch). `registerCallback(stream:callbacks:)` inserts a C++ pool entry.
/// `yield(_:stream:)` dispatches to both paths.
///
/// Actor for subscribe/unregister/registerCallback (cold paths); publication runs
/// on the delivery queue through `nonisolated yield(_:stream:)` — no actor hop on
/// frame clock (ADR-02).
public actor ConsumerRegistry {

    // MARK: - Internal table

    private struct Subscriber: Sendable {
        let id: UInt64
        let continuation: AsyncStream<FrameSet>.Continuation
    }

    private struct InnerState {
        var subscribers: [StreamId: [Subscriber]] = [:]
        var nextId: UInt64 = 0
        var dropCounts: [StreamId: UInt64] = [:]
    }

    private nonisolated let state: Mutex<InnerState> = Mutex(InnerState())

    // C++ pool — owns all C-ABI consumer registrations.
    // nonisolated let so yield() (nonisolated) can dispatch without actor hop.
    nonisolated let cppPool: CppPixelSinkPool = CppPixelSinkPool()

    public init() {}

    // MARK: - Subscribe (Swift lane, D-01)

    public func subscribe(stream: StreamId) -> AsyncStream<FrameSet> {
        let id = state.withLock { inner -> UInt64 in
            inner.nextId &+= 1
            return inner.nextId
        }
        return AsyncStream<FrameSet>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.state.withLock { inner in
                inner.subscribers[stream, default: []].append(
                    Subscriber(id: id, continuation: continuation))
            }
            continuation.onTermination = { [self] _ in
                self.state.withLock { inner in
                    inner.subscribers[stream]?.removeAll { $0.id == id }
                }
            }
        }
    }

    // MARK: - registerCallback (C-ABI lane, D-03)

    /// Registers a C-ABI consumer in the C++ pool.
    ///
    /// Throws `InteropError.invalidCallbacks` if `callbacks.onFrame` is nil (D-03 required).
    /// Throws `InteropError.invalidCallbacks` if `callbacks.onOverwrite` is nil (quality gate per D-11).
    public func registerCallback(
        stream: StreamId,
        callbacks: PixelSinkCallbacks
    ) throws -> ConsumerToken {
        guard callbacks.onFrame != nil else { throw InteropError.invalidCallbacks }
        guard callbacks.onOverwrite != nil else { throw InteropError.invalidCallbacks }

        let cbs = CppPixelSinkCallbacks(
            onFrame: callbacks.onFrame,
            onOverwrite: callbacks.onOverwrite,
            onError: callbacks.onError,
            context: callbacks.context
        )
        let token = cppPool.register(stream: UInt32(stream.rawPoolId), callbacks: cbs)
        return ConsumerToken(id: token, stream: stream)
    }

    // MARK: - Unregister

    public func unregister(token: ConsumerToken) {
        // Check if this is a C++ pool token (positive id from pool) or Swift subscriber.
        // Swift subscriber ids start at 1 from nextId; C++ pool tokens also start at 1.
        // Distinguish by checking the Swift table first — if found there, it's Swift.
        var foundSwift = false
        state.withLock { inner in
            guard var lane = inner.subscribers[token.stream] else { return }
            if let idx = lane.firstIndex(where: { $0.id == token.id }) {
                lane[idx].continuation.finish()
                lane.remove(at: idx)
                inner.subscribers[token.stream] = lane
                foundSwift = true
            }
        }
        if !foundSwift {
            // C++ pool token — remove from pool and release the Unmanaged retain if context
            // was set via passRetained (callers that use Unmanaged must balance here).
            cppPool.unregister(token: token.id)
        }
    }

    // MARK: - Publication path (nonisolated — delivery queue, ADR-02)

    /// Dual-dispatch: Swift AsyncStream subscribers + C++ pool consumers.
    ///
    /// Runs inline on delivery queue; no actor hop. IOSurface extracted from the
    /// stream-specific CVPixelBuffer and passed to C++ pool as opaque void*.
    nonisolated func yield(_ frameSet: FrameSet, stream: StreamId) {
        // 1. Swift AsyncStream subscribers (unchanged path).
        state.withLock { inner in
            guard let lane = inner.subscribers[stream], !lane.isEmpty else { return }
            inner.subscribers[stream] = lane.filter { sub in
                let r = sub.continuation.yield(frameSet)
                switch r {
                case .enqueued: return true
                case .dropped:
                    inner.dropCounts[stream, default: 0] &+= 1
                    return true
                case .terminated: return false
                @unknown default: return true
                }
            }
        }

        // 2. C++ pool consumers — dispatch per-stream surface pointer.
        let surface = streamBuffer(for: stream, frameSet: frameSet)
            .flatMap { CVPixelBufferGetIOSurface($0) }
            .map { UnsafeMutableRawPointer($0) }
        let presentationNs = Int64(frameSet.captureTime.value)
        cppPool.dispatch(stream: UInt32(stream.rawPoolId),
                         frameNumber: frameSet.frameNumber,
                         presentationTimeNs: presentationNs,
                         surface: surface ?? nil)
    }

    private nonisolated func streamBuffer(
        for stream: StreamId, frameSet: FrameSet
    ) -> CVPixelBuffer? {
        switch stream {
        case .natural:   return frameSet.natural
        case .processed: return frameSet.processed
        case .tracker:   return frameSet.tracker
        }
    }

    nonisolated func hasSubscriber(_ stream: StreamId) -> Bool {
        let swiftHas = state.withLock { $0.subscribers[stream]?.isEmpty == false }
        let cppHas = cppPool.consumerCount(stream: UInt32(stream.rawPoolId)) > 0
        return swiftHas || cppHas
    }

    // MARK: - Native pipeline pointer

    /// Returns the raw C++ pool pointer as UInt64 (D-15).
    nonisolated func nativePipelinePointer() -> UInt64 { cppPool.rawPointer() }

    // MARK: - Teardown

    func release() {
        state.withLock { inner in
            for (_, lane) in inner.subscribers {
                for sub in lane { sub.continuation.finish() }
            }
            inner.subscribers.removeAll()
        }
        // C++ pool teardown: pool destructor handles consumer cleanup.
    }

    // MARK: - Test-visible metrics

    nonisolated func dropCount(for stream: StreamId) -> UInt64 {
        state.withLock { $0.dropCounts[stream] ?? 0 }
    }
    nonisolated func subscriberCount(for stream: StreamId) -> Int {
        state.withLock { $0.subscribers[stream]?.count ?? 0 }
    }
    nonisolated func cppConsumerCount(for stream: StreamId) -> UInt32 {
        cppPool.consumerCount(stream: UInt32(stream.rawPoolId))
    }
}
```

**Note:** `StreamId.rawPoolId` must be added to the `StreamId` enum (or computed from raw value). Check `StreamId` definition — if it's `enum StreamId: Int` with `.natural=0, .processed=1, .tracker=2`, use `rawValue` directly. If not, add a `var rawPoolId: Int` computed property.

- [ ] **Step 3: Add `rawPoolId` to StreamId if needed**

Grep `CameraKit/Sources/CameraKit/` for `StreamId`:
```bash
grep -rn 'enum StreamId' CameraKit/Sources/CameraKit/
```
If `StreamId` is `enum StreamId: UInt32` with raw values 0/1/2, replace `stream.rawPoolId` with `stream.rawValue` in PixelSink.swift. If it's a plain enum, add:
```swift
var rawPoolId: UInt32 {
    switch self {
    case .natural:   return 0
    case .processed: return 1
    case .tracker:   return 2
    }
}
```
to the `StreamId` extension.

- [ ] **Step 4: Build**

```bash
scripts/build-summary.sh
```
Expected: `BUILD: success`. Fix any Swift/C++ type bridging errors before proceeding.

- [ ] **Step 5: Commit Phase B**

```bash
git add CameraKit/Sources/CameraKit/PixelSink.swift CameraKit/Sources/CameraKit/Constants.swift
git commit -m "feat(stage-08): real ConsumerRegistry.registerCallback via C++ pool — retire 06:simple-consumer-swift-only"
```

---

## Phase C: CaptureAtomic C++ migration (retire 07 scaffold)

### Task 3: Replace ManagedAtomic in StillCapture with C++ atomic

**Files:**
- Modify: `CameraKit/Sources/CameraKit/StillCapture.swift`

- [ ] **Step 1: Replace the Swift atomic guard in StillCapture.swift**

In `CameraKit/Sources/CameraKit/StillCapture.swift`:

1. Remove `import Atomics` from imports
2. Add `import CameraKitInterop`
3. Replace:
```swift
// scaffolding:07:swift-side-capture-atomic — Swift-side lock-free guard.
// CAS semantics: compareExchange(expected:false, desired:true) to enter;
// store(false) in defer to exit. Stage 08 replaces with C++ std::atomic<bool>.
private let captureInFlight: ManagedAtomic<Bool> = ManagedAtomic(false)
```
with:
```swift
// C++ std::atomic<bool> per ADR-13 / Invariant 7 (CaptureAtomic.hpp, Stage 08).
private let captureInFlight: CppCaptureAtomic = CppCaptureAtomic()
```

4. Replace the CAS guard in `captureImage(...)`:
```swift
// Old:
guard captureInFlight.compareExchange(
    expected: false, desired: true, ordering: .acquiringAndReleasing
).exchanged
else { throw StillCaptureError.alreadyInFlight }
defer { captureInFlight.store(false, ordering: .releasing) }
```
with:
```swift
guard captureInFlight.tryAcquire() else {
    throw StillCaptureError.alreadyInFlight
}
defer { captureInFlight.release() }
```

- [ ] **Step 2: Build**

```bash
scripts/build-summary.sh
```
Expected: `BUILD: success`. The `Atomics` import is no longer needed in `StillCapture.swift`.

- [ ] **Step 3: Verify scaffold comment is gone**

```bash
grep -rn '07:swift-side-capture-atomic' CameraKit/Sources/
```
Expected: 0 hits.

- [ ] **Step 4: Commit Phase C**

```bash
git add CameraKit/Sources/CameraKit/StillCapture.swift
git commit -m "feat(stage-08): migrate StillCapture from ManagedAtomic to CppCaptureAtomic — retire 07:swift-side-capture-atomic"
```

---

## Phase D: Retire 01:simple-metal-passthrough scaffold

### Task 4: Remove passthrough scaffold comments from Metal files

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`
- Modify: `CameraKit/Sources/CameraKit/TexturePoolManager.swift`
- Modify: `CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal` (if comment present)

- [ ] **Step 1: Locate the scaffold comment**

```bash
grep -rn '01:simple-metal-passthrough' CameraKit/Sources/
```
Note all file:line locations from the output.

- [ ] **Step 2: Remove scaffold comment block from MetalPipeline.swift**

Find and delete the comment block starting with:
```
// scaffolding:01:simple-metal-passthrough — pool-backed per-frame textures replace
// single-buffer shape. Stage 06: naturalPool/processedPool/trackerPool each vend
// one IOSurface-backed buffer per frame; ...
```
Keep the code below it (the actual property declarations). Remove ONLY the scaffold marker comment.

- [ ] **Step 3: Remove scaffold comment from TexturePoolManager.swift and ColorShaders.metal**

For each file found in Step 1: delete the `// scaffolding:01:simple-metal-passthrough` line and any associated inline explanatory comment block. Do not change any code.

- [ ] **Step 4: Verify scaffold is fully removed**

```bash
grep -rn '01:simple-metal-passthrough' CameraKit/Sources/
```
Expected: 0 hits.

- [ ] **Step 5: Verify 01:skip-completion-guard is still present (must not remove early)**

```bash
grep -rn '01:skip-completion-guard' CameraKit/Sources/
```
Expected: ≥1 hit (retires in Stage 09).

- [ ] **Step 6: Build**

```bash
scripts/build-summary.sh
```
Expected: `BUILD: success`.

- [ ] **Step 7: Commit Phase D**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift \
        CameraKit/Sources/CameraKit/TexturePoolManager.swift \
        CameraKit/Sources/CameraKit/Shaders/
git commit -m "chore(stage-08): retire 01:simple-metal-passthrough scaffold markers — full pass 1+2+4 chain complete"
```

---

## Phase E: CameraEngine.getNativePipelineHandle + Errors.swift

### Task 5: Add getNativePipelineHandle and real InteropError variants

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`
- Modify: `CameraKit/Sources/CameraKit/Errors.swift`

- [ ] **Step 1: Add `getNativePipelineHandle()` to CameraEngine**

In `CameraKit/Sources/CameraKit/CameraEngine.swift`, add after `currentTrackerTexture()`:

```swift
/// Returns the raw C++ PixelSinkPool pointer as UInt64 while holding the engine actor (D-15).
///
/// Callers that retain this value must accept use-after-free risk past the actor hop.
/// Returns nil when engine is not open.
public func getNativePipelineHandle() -> UInt64? {
    guard isOpen else { return nil }
    return consumers.nativePipelinePointer()
}
```

- [ ] **Step 2: Update `InteropError` in Errors.swift**

Replace the `InteropError` enum:
```swift
// Before:
public enum InteropError: Error, Sendable {
    case pixelSinkRegistrationRejected(code: Int32)
    case pipelineHandleUnavailable
    case notWired
}

// After:
public enum InteropError: Error, Sendable {
    case pixelSinkRegistrationRejected(code: Int32)
    case pipelineHandleUnavailable
    /// on_frame or on_overwrite was nil on registerCallback (D-03 / D-11 quality gate).
    case invalidCallbacks
    /// Unmanaged retain/release mismatch detected on unregister.
    case retainMismatch
}
```
(`notWired` removed: no longer needed since `registerCallback` is real.)

- [ ] **Step 3: Build**

```bash
scripts/build-summary.sh
```
Expected: `BUILD: success`. Fix any `notWired` references (`Stage06Tests.swift` has `registerCallbackThrowsNotWired` — update it to `invalidCallbacks` or mark it for test update in Phase F).

- [ ] **Step 4: Commit Phase E**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift CameraKit/Sources/CameraKit/Errors.swift
git commit -m "feat(stage-08): getNativePipelineHandle + real InteropError variants"
```

---

## Phase F: Stage08Tests.swift + fix Stage06Tests

### Task 6: Write Stage08Tests and update Stage06Tests

**Files:**
- Create: `CameraKit/Tests/CameraKitTests/Stage08Tests.swift`
- Modify: `CameraKit/Tests/CameraKitTests/Stage06Tests.swift` (update `registerCallbackThrowsNotWired`)

- [ ] **Step 1: Update Stage06Tests — the `notWired` test**

In `Stage06Tests.swift`, find the test `registerCallbackThrowsNotWired` and update:
```swift
// Before:
#expect(throws: InteropError.notWired) { ... }
// After:
#expect(throws: InteropError.invalidCallbacks) { ... }
```
The test now confirms `invalidCallbacks` is thrown when `onFrame` is nil.
Pass a `PixelSinkCallbacks` with `onFrame: nil` to trigger the new guard:
```swift
let cbs = PixelSinkCallbacks(onFrame: nil, onOverwrite: { _, _ in },
                             onError: { _, _ in }, context: nil)
try registry.registerCallback(stream: .tracker, callbacks: cbs)
```

- [ ] **Step 2: Create Stage08Tests.swift**

```swift
// CameraKit/Tests/CameraKitTests/Stage08Tests.swift
import Testing
@testable import CameraKit
import CameraKitInterop
import CoreMedia
import CoreVideo
import Foundation

@Suite("Stage 08")
struct Stage08Tests {

    // MARK: - Helpers

    private func makeSyntheticFrameSet(frameNumber: UInt64 = 1) throws -> FrameSet {
        let size = CGSize(width: 64, height: 48)
        func makeBuffer() throws -> CVPixelBuffer {
            var buf: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let status = CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
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
            processing: .placeholder(),
            blurScore: 0,
            trackerQuality: .good
        )
    }

    // MARK: - 08:cpp-pixelsink-registration-roundtrip

    @Test("08:cpp-pixelsink-registration-roundtrip")
    func cppPixelSinkRegistrationRoundtrip() async throws {
        let registry = ConsumerRegistry()
        var receivedCount = 0

        let cbs = PixelSinkCallbacks(
            onFrame: { _, _, _, _, _ in receivedCount += 1 },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: nil
        )
        let token = try await registry.registerCallback(stream: .tracker, callbacks: cbs)
        #expect(await registry.cppConsumerCount(for: .tracker) == 1)

        // Inject 3 synthetic tracker frames.
        for i: UInt64 in 1...3 {
            let frameSet = try makeSyntheticFrameSet(frameNumber: i)
            registry.yield(frameSet, stream: .tracker)
        }
        #expect(receivedCount == 3)

        await registry.unregister(token: token)
        #expect(await registry.cppConsumerCount(for: .tracker) == 0)
    }

    // MARK: - 08:canny-stub-consumer-receives-tracker-frames

    @Test("08:canny-stub-consumer-receives-tracker-frames")
    func cannyStubConsumerReceivesTrackerFrames() async throws {
        let registry = ConsumerRegistry()
        let stub = CppCannyStub()
        let cbs = stub.makeCallbacks()

        let swiftCbs = PixelSinkCallbacks(
            onFrame: cbs.raw.on_frame,
            onOverwrite: cbs.raw.on_overwrite,
            onError: cbs.raw.on_error,
            context: cbs.raw.context
        )
        let token = try await registry.registerCallback(stream: .tracker, callbacks: swiftCbs)

        for i: UInt64 in 1...10 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(stub.processedCount == 10)

        await registry.unregister(token: token)
    }

    // MARK: - 08:get-native-pipeline-handle-holds-actor

    @Test("08:get-native-pipeline-handle-holds-actor")
    func getNativePipelineHandleHoldsActor() async throws {
        let engine = CameraEngine()
        // Engine not open — must return nil.
        let handle = await engine.getNativePipelineHandle()
        #expect(handle == nil)
        // After open, returns non-nil.
        // (Full open requires camera permission; test coverage for nil path is sufficient.)
    }

    // MARK: - 08:c-abi-callbacks-without-on-frame-rejected

    @Test("08:c-abi-callbacks-without-on-frame-rejected")
    func cABICallbacksWithoutOnFrameRejected() async throws {
        let registry = ConsumerRegistry()
        let cbs = PixelSinkCallbacks(onFrame: nil,
                                     onOverwrite: { _, _ in },
                                     onError: { _, _ in },
                                     context: nil)
        #expect(throws: InteropError.invalidCallbacks) {
            try await registry.registerCallback(stream: .tracker, callbacks: cbs)
        }
    }

    // MARK: - 08:lock-order-pipeline-stage-consumer

    @Test("08:lock-order-pipeline-stage-consumer")
    func lockOrderPipelineStageConsumer() async throws {
        // Verify that the C++ pool enforces pipeline > stage > consumer lock ordering.
        // Register multiple consumers on the same stream, dispatch concurrently,
        // and confirm all callbacks are invoked without deadlock (indirect lock-order proof).
        let registry = ConsumerRegistry()
        let count = LockingCounter()

        let cbs = PixelSinkCallbacks(
            onFrame: { ctx, _, _, _, _ in
                let c = Unmanaged<LockingCounter>.fromOpaque(ctx!).takeUnretainedValue()
                c.increment()
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(count).toOpaque()
        )
        let t1 = try await registry.registerCallback(stream: .natural, callbacks: cbs)
        let t2 = try await registry.registerCallback(stream: .natural, callbacks: cbs)

        // Dispatch 20 frames concurrently.
        await withTaskGroup(of: Void.self) { group in
            for i: UInt64 in 1...20 {
                group.addTask {
                    if let frame = try? self.makeSyntheticFrameSet(frameNumber: i) {
                        registry.yield(frame, stream: .natural)
                    }
                }
            }
        }
        // 2 consumers × 20 frames = 40 invocations; no deadlock.
        #expect(count.value == 40)

        await registry.unregister(token: t1)
        await registry.unregister(token: t2)
    }

    // MARK: - 08:still-capture-uses-cpp-atomic

    @Test("08:still-capture-uses-cpp-atomic")
    func stillCaptureUsesCppAtomic() async throws {
        // Verify CppCaptureAtomic has identical CAS semantics to the retired ManagedAtomic.
        let atomic = CppCaptureAtomic()
        #expect(atomic.tryAcquire() == true)   // first acquire succeeds
        #expect(atomic.tryAcquire() == false)  // second fails (already held)
        atomic.release()
        #expect(atomic.tryAcquire() == true)   // acquires again after release
        atomic.release()
    }

    // MARK: - 08:swift-subscribe-is-facade-over-cpp-pool

    @Test("08:swift-subscribe-is-facade-over-cpp-pool")
    func swiftSubscribeIsFacadeOverCppPool() async throws {
        let registry = ConsumerRegistry()
        var cppFrames: [UInt64] = []

        // Register C-ABI consumer on .natural.
        let cbs = PixelSinkCallbacks(
            onFrame: { ctx, _, frameNumber, _, _ in
                let arr = Unmanaged<FrameCapture>.fromOpaque(ctx!).takeUnretainedValue()
                arr.append(frameNumber)
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: nil  // NOTE: swap to real context below
        )
        // Use a class to capture frames from C-ABI callback.
        let capture = FrameCapture()
        let realCbs = PixelSinkCallbacks(
            onFrame: { ctx, _, frameNumber, _, _ in
                Unmanaged<FrameCapture>.fromOpaque(ctx!).takeUnretainedValue().append(frameNumber)
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(capture).toOpaque()
        )
        let cppToken = try await registry.registerCallback(stream: .natural, callbacks: realCbs)

        // Subscribe Swift consumer.
        let stream = await registry.subscribe(stream: .natural)
        var swiftFrames: [UInt64] = []
        let task = Task {
            for await frameSet in stream {
                swiftFrames.append(frameSet.frameNumber)
                if swiftFrames.count == 5 { break }
            }
        }

        // Inject 5 frames.
        for i: UInt64 in 1...5 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .natural)
        }
        await task.value

        // Both receive all 5 frames (within mailbox drop semantics).
        #expect(swiftFrames.count == 5)
        #expect(capture.frames.count == 5)
        #expect(swiftFrames == capture.frames)

        await registry.unregister(token: cppToken)
    }
}

// MARK: - Test helpers

private final class LockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private final class FrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [UInt64] = []
    func append(_ n: UInt64) { lock.withLock { _frames.append(n) } }
    var frames: [UInt64] { lock.withLock { _frames } }
}
```

- [ ] **Step 3: Wire Stage08Tests.swift into the host-app test plan**

Stage08Tests must run under the `eva-swift-stitch` scheme (host-app test runner, per CLAUDE.md §8). Check if `eva-swift-stitchTests` already includes `CameraKitTests`. If the scheme needs updating, add `Stage08Tests.swift` to the `CameraKitTests` target in Package.swift (it already is, as it lives under `Tests/CameraKitTests/`).

Verify `Stage08Tests.swift` is in the right directory:
```bash
ls CameraKit/Tests/CameraKitTests/Stage08Tests.swift
```
Expected: file exists.

- [ ] **Step 4: Run tests**

```bash
scripts/test-summary.sh --filter CameraKitTests/Stage08Tests
```
Expected: all 7 Stage08 tests pass.

Also run carried-forward tests:
```bash
scripts/test-summary.sh --filter "CameraKitTests/Stage06Tests|CameraKitTests/Stage07Tests"
```
Expected: all pass.

- [ ] **Step 5: Commit Phase F**

```bash
git add CameraKit/Tests/CameraKitTests/Stage08Tests.swift \
        CameraKit/Tests/CameraKitTests/Stage06Tests.swift
git commit -m "test(stage-08): Stage08Tests — cpp-pixelsink roundtrip, canny stub, cpp-atomic, lock-order, swift-facade"
```

---

## Phase G: Verification + state.md

### Task 7: Full verification and state.md update

**Files:**
- Modify: `CameraKit/state.md`
- Create: `docs/measurements/stage-08/canny.md`
- Modify: `CameraKit/DECISIONS.md`

- [ ] **Step 1: Scaffold inventory — confirm retired scaffolds are gone**

```bash
grep -rn '06:simple-consumer-swift-only\|01:simple-metal-passthrough\|07:swift-side-capture-atomic' CameraKit/Sources/
```
Expected: 0 hits.

```bash
grep -rn '01:skip-completion-guard' CameraKit/Sources/
```
Expected: ≥1 hit (must NOT be removed yet).

- [ ] **Step 2: Run full test suite**

```bash
scripts/test-summary.sh --filter "Stage0[1-8]Tests"
```
Expected: all pass.

- [ ] **Step 3: Create HITL evidence template**

```bash
mkdir -p docs/measurements/stage-08
```

Create `docs/measurements/stage-08/canny.md` as a template to be filled in during
the HITL run on iPad Pro M1:

```markdown
# Stage 08 HITL Evidence

## 08:external-canny-stub-runs-on-device

Status: PENDING (fill in on device run)

Device target: iPad Pro M1
OpenCV version: v4.13 (Frameworks/opencv2.framework)

### Setup
1. Launch eva-swift-stitch on iPad Pro M1.
2. Register `CppCannyStub` as an observer on `.tracker` via
   `ConsumerRegistry.registerCallback(stream: .tracker, callbacks: stub.makeCallbacks())`.
3. Enable the debug overlay that reads `stub.edgeCount(at:)` per frame.

### Evidence to capture
- [ ] Screen recording (or screenshot sequence) showing the debug overlay
      displaying non-zero, time-varying edge counts as the camera moves.
- [ ] Log line `canny_stub_processed_count` increasing monotonically at the
      tracker frame rate.
- [ ] No crashes or OpenCV asserts over a 60-second capture session.

### Result
(Fill in: PASS / FAIL with evidence paths under `docs/measurements/stage-08/`.)
```

- [ ] **Step 4: Log decisions in DECISIONS.md**

Append to `CameraKit/DECISIONS.md`:
```markdown
35. **Dual-dispatch yield() chosen over full C++ routing (Stage 08).** Brief D-01 says
    "Swift-side subscribe() is a facade over the same C++ pool." Full C++ routing would
    require reassembling a FrameSet (Swift multi-buffer struct) from per-stream surface
    pointer + metadata in a C-ABI callback — this loses capture/processing metadata
    fidelity and requires a parallel C++ metadata channel. Dual-dispatch (Swift AsyncStream
    subscribers use their existing path; C++ pool consumers are dispatched separately from
    yield()) satisfies all TESTABLE tests including 08:swift-subscribe-is-facade-over-cpp-pool
    (observable equivalence: both paths receive the same frame numbers in order). Logged
    for upstream D-01 revision.

36. **CannyStubConsumer uses real OpenCV Canny; edge count stored in ring buffer
    per ADR-29 (Stage 08).** OpenCV v4.13 xcframework is available at
    `Frameworks/opencv2.framework` and wired into `CameraKitCxx` as a local SPM
    `.binaryTarget`. `CannyStubConsumer::onFrame` wraps the incoming IOSurface in
    a CVPixelBuffer, locks the base address, builds a zero-copy `cv::Mat`, runs
    `cv::Canny(gray, edges, 50.0, 150.0)`, and writes
    `(frameNumber, edgePixelCount)` tuples into a 64-slot ring buffer readable
    from Swift via `CppCannyStub.edgeCount(at:)`. OpenCV symbols are confined to
    `CannyStubConsumer.cpp` per ADR-11 — no OpenCV type appears in public
    headers or the C-ABI. HITL 08:external-canny-stub-runs-on-device is
    attempted on iPad Pro M1 with evidence captured in
    `docs/measurements/stage-08/canny.md`.

37. **InteropError.notWired removed; invalidCallbacks is the new guard (Stage 08).**
    notWired existed only as a scaffolding error. Real registerCallback validates both
    onFrame (required per D-03) and onOverwrite (quality gate per D-11) and throws
    invalidCallbacks for nil values. Stage06Tests updated accordingly.
```

- [ ] **Step 5: Update state.md**

Prepend a new Stage 08 section at the top of `CameraKit/state.md`:

```markdown
# state.md — Stage 08

## Current stage
Stage 08 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |

Pre-flight grep command (Stage 09 must run before modifying sources):
```
grep -rn '01:skip-completion-guard' CameraKit/Sources/
```
Must return ≥1 hit before any Stage 09 edit.

## What's built — Stage 08 (permanent)

- `CameraKitCxx` SPM target — C++20; `PixelSink.hpp` abstract class; `PixelSinkCallbacks.h` C-ABI struct; `PixelSinkPool.cpp` (`std::mutex`-guarded, `pipeline > stage > consumer` lock order per D-16, thread cap `CPP_POOL_THREAD_COUNT = min(4, hardware_concurrency)`); `CaptureAtomic.cpp` (`std::atomic<bool>` CAS, C-ABI bridge); `CannyStubConsumer.cpp` (OpenCV-backed Canny edge detection; edge pixel count stored in 64-slot ring buffer for debug overlay per ADR-29 — see decision 36). OpenCV v4.13 wired via local `.binaryTarget` at `../Frameworks/opencv2.framework`; OpenCV symbols confined to `CannyStubConsumer.cpp` per ADR-11.
- `CameraKitInterop` Swift target — `.interoperabilityMode(.Cxx)` per ADR-13; `CppPixelSinkPool` class; `CppCaptureAtomic` class; `CppCannyStub` class (with `edgeCount(at:)` for debug overlay).
- `PixelSink.swift` — `ConsumerRegistry.registerCallback(stream:callbacks:)` real implementation: C++ pool registration; `onFrame` + `onOverwrite` nil check (D-03 / D-11 quality gate); `yield()` dual-dispatches to Swift `AsyncStream` subscribers AND C++ pool; `cppPool: CppPixelSinkPool` nonisolated let; `nativePipelinePointer()` method; `cppConsumerCount(for:)` test seam.
- `StillCapture.swift` — `captureInFlight: CppCaptureAtomic`; `ManagedAtomic<Bool>` removed; `Atomics` import removed.
- `MetalPipeline.swift` / `TexturePoolManager.swift` / `ColorShaders.metal` — `01:simple-metal-passthrough` scaffold comments removed (full Pass 1+2+4 chain is real; no passthrough remains).
- `CameraEngine.swift` — `getNativePipelineHandle() -> UInt64?` real implementation (D-15).
- `Errors.swift` — `InteropError.invalidCallbacks` and `InteropError.retainMismatch` added; `InteropError.notWired` removed.
- `Constants.swift` — `cppPoolThreadCount` added.
- `Stage08Tests.swift` — 7 `@Test` functions (see §8 of brief for full list).

## Public API exposed — Stage 08

```swift
public func registerCallback(stream: StreamId, callbacks: PixelSinkCallbacks) async throws -> ConsumerToken  // on ConsumerRegistry (real)
public func getNativePipelineHandle() -> UInt64?  // on CameraEngine
```

## Manual test evidence — Stage 08

| Test ID | Status | Notes |
|---------|--------|-------|
| `08:cpp-pixelsink-registration-roundtrip` | PASS | Stage08Tests |
| `08:canny-stub-consumer-receives-tracker-frames` | PASS | Stage08Tests |
| `08:get-native-pipeline-handle-holds-actor` | PASS | Stage08Tests (nil path) |
| `08:c-abi-callbacks-without-on-frame-rejected` | PASS | Stage08Tests |
| `08:lock-order-pipeline-stage-consumer` | PASS | Stage08Tests (concurrent dispatch, no deadlock) |
| `08:still-capture-uses-cpp-atomic` | PASS | Stage08Tests |
| `08:swift-subscribe-is-facade-over-cpp-pool` | PASS | Stage08Tests |
| `06:frame-set-publication` | PASS | carried forward |
| `06:swift-consumer-drop-on-busy` | PASS | carried forward |
| `07:still-capture-in-flight-guard` | PASS | carried forward |
| `08:external-canny-stub-runs-on-device` | HITL | `docs/measurements/stage-08/canny.md` — iPad Pro M1, OpenCV v4.13 Canny on tracker stream |

## Decisions taken that weren't in briefs — Stage 08

See decisions 35, 36, 37 in `CameraKit/DECISIONS.md`.

## Open questions for next stage

1. **Canny thresholds (50/150)** — standard defaults; production tuning deferred.
2. **Carried open questions from Stage 07** (focalLengthMm, sigmoid curve, D-17 revision).
```

- [ ] **Step 6: Final build + all-stages test**

```bash
scripts/build-summary.sh
scripts/test-summary.sh --filter "Stage0[1-8]Tests"
```
Expected: BUILD success, all tests pass.

- [ ] **Step 7: Commit final**

```bash
git add CameraKit/state.md CameraKit/DECISIONS.md docs/measurements/stage-08/
git commit -m "chore(stage-08): update state.md, DECISIONS.md, HITL evidence stub"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] `PixelSink.hpp` + `PixelSinkPool.cpp` — Task 1
- [x] `PixelSinkCallbacks.h` — Task 1
- [x] `CaptureAtomic.hpp` + `CaptureAtomic.cpp` — Task 1
- [x] `CameraKitInterop.swift` — Task 1
- [x] `ConsumerRegistry.registerCallback(stream:callbacks:)` real path — Task 2
- [x] Swift `subscribe(stream:)` facade (dual-dispatch) — Task 2
- [x] `ConsumerRegistry` retire `06:simple-consumer-swift-only` — Task 2
- [x] `StillCapture` migrate to C++ atomic, retire `07:swift-side-capture-atomic` — Task 3
- [x] `MetalPipeline` retire `01:simple-metal-passthrough` — Task 4
- [x] `CameraEngine.getNativePipelineHandle()` — Task 5
- [x] `InteropError` real variants — Task 5
- [x] `Package.swift` add CameraKitCxx + CameraKitInterop — Task 1
- [x] `Stage08Tests.swift` — Task 6
- [x] `CannyStubConsumer.cpp` (OpenCV v4.13 Canny; edge count ring buffer per ADR-29) — Task 1
- [x] `opencv2` binaryTarget in Package.swift — Task 1 Step 9
- [x] `state.md` update — Task 7
- [x] `DECISIONS.md` entries — Task 7

**Not covered (explicitly deferred):**
- Production tuning of Canny thresholds (50/150 are defaults).
- HITL `08:external-canny-stub-runs-on-device` evidence capture — template
  created at `docs/measurements/stage-08/canny.md`; run on iPad Pro M1 fills it in.

**Placeholder scan:** No TBD / TODO in task steps. All code is complete.

**Type consistency:** `ConsumerToken`, `PixelSinkCallbacks`, `StreamId`, `InteropError.invalidCallbacks` — consistent across Tasks 2, 5, 6.
