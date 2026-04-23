// PixelSinkPool — C++ PixelSink pool with pipeline > stage > consumer lock ordering (D-16).
// Thread cap: CPP_POOL_THREAD_COUNT = min(4, hardware_concurrency).
#include "PixelSink.hpp"
#include "PixelSinkCallbacks.h"
#include <mutex>
#include <vector>
#include <thread>
#include <algorithm>
#include <cstdint>

static constexpr unsigned kMaxThreads = CPP_POOL_THREAD_COUNT;

struct ConsumerEntry {
    uint64_t           token;
    PixelSinkCallbacks cbs;
    uint32_t           stream;
};

class PixelSinkPool {
public:
    PixelSinkPool()
        : threadCount_(std::min(kMaxThreads,
                                std::thread::hardware_concurrency())) {}

    uint64_t registerConsumer(uint32_t stream, PixelSinkCallbacks cbs) {
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
        uint64_t id = nextId_++;
        consumers_.push_back({id, cbs, stream});
        return id;
    }

    void unregisterConsumer(uint64_t token) {
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
        consumers_.erase(
            std::remove_if(consumers_.begin(), consumers_.end(),
                [token](const ConsumerEntry& e) { return e.token == token; }),
            consumers_.end());
    }

    void dispatch(uint32_t stream, uint64_t frameNumber,
                  int64_t presentationTimeNs, void* surface) {
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
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
            if (e.stream == stream) { n++; }
        }
        return n;
    }

    uintptr_t rawPointer() const { return reinterpret_cast<uintptr_t>(this); }

private:
    mutable std::mutex pipelineMutex_;
    mutable std::mutex stageMutex_;
    mutable std::mutex consumerMutex_;
    std::vector<ConsumerEntry> consumers_;
    uint64_t nextId_ = 1;
    unsigned threadCount_;
};

extern "C" {

void* pixel_sink_pool_create(void) { return new PixelSinkPool(); }

void pixel_sink_pool_destroy(void* handle) {
    delete static_cast<PixelSinkPool*>(handle);
}

uint64_t pixel_sink_pool_register(void* handle, uint32_t stream, PixelSinkCallbacks cbs) {
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
