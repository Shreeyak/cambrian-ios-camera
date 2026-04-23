// CannyStubConsumer — OpenCV-backed Canny edge detection per ADR-29.
// Incoming frames come as IOSurfaceRef (void*) from the tracker stream.
// We wrap via CVPixelBufferRef for safe, lockable pixel base address access,
// run cv::Canny, and write (frameNumber, edgePixelCount) tuples into a
// fixed-size ring buffer that the debug overlay reads back via C-ABI.
// OpenCV is confined to CameraKitCxx; no OpenCV symbol escapes (ADR-11).
#include "PixelSink.hpp"
#include "PixelSinkCallbacks.h"
#include <opencv2/imgproc.hpp>
#include <opencv2/core.hpp>
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <array>
#include <cstdint>

static constexpr size_t kRingSize    = 64;
static constexpr double kCannyLow    = 50.0;
static constexpr double kCannyHigh   = 150.0;

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
                         int64_t presentationTimeNs, void* surface) {
    PixelFrame f{stream, frameNumber, presentationTimeNs, surface};
    static_cast<CannyStubConsumer*>(context)->onFrame(f);
}

uint64_t canny_stub_processed_count(void* handle) {
    return static_cast<CannyStubConsumer*>(handle)->processedCount();
}

uint32_t canny_stub_edge_count(void* handle, size_t idx) {
    return static_cast<CannyStubConsumer*>(handle)->edgeCountAt(idx);
}

}  // extern "C"
