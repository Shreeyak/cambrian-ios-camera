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
