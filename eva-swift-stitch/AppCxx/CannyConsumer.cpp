// CannyConsumer — OpenCV-backed Canny edge detection per ADR-29.
// Phase 1B (2026-05-15) — relocated from CameraKit/Sources/CameraKitCxx/
// CannyStubConsumer.cpp into the eva-swift-stitch app target so the
// CameraKit package becomes OpenCV-free.
//
// Receives tracker-stream frames via the C-ABI canny_stub_on_frame entrypoint
// (the C++ pool calls it through a PixelSinkCallbacks function pointer).
// Stores (frameNumber, edgePixelCount) tuples into a fixed-size ring buffer
// the debug overlay reads back via canny_stub_processed_count / _edge_count.
//
// Self-contained: does NOT inherit from PixelSink. The C-ABI thunk was the
// only caller of the virtual onFrame override; the inheritance was structurally
// dead. Dropping it removed the PixelSink.hpp / PixelFrame dependency, which
// is what makes this file's relocation a clean byte-move.
#include "include/CannyConsumer.h"
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
