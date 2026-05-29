// CounterConsumer — minimal C-ABI parity probe per Phase 1B.
// Counts frames per stream; no image processing. Registered against the
// engine's raw pool pointer via the C-ABI pixel_sink_pool_register, exactly
// as Phase 3's Flutter plugin native code will.
#include "include/CounterConsumer.h"
#include <PixelSinkCallbacks.h>   // from CameraKit/Sources/CameraKitCxx/include
                                  // via HEADER_SEARCH_PATHS (set in Task 6).
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
