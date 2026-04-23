#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - C-ABI callback function pointer types (D-03)

typedef void (*OnFrameFn)(void* context, uint32_t stream,
                          uint64_t frameNumber, int64_t presentationTimeNs,
                          void* surface);
typedef void (*OnOverwriteFn)(void* context, uint32_t stream);
typedef void (*OnErrorFn)(void* context, int32_t code);

typedef struct {
    OnFrameFn     on_frame;
    OnOverwriteFn on_overwrite;
    OnErrorFn     on_error;
    void*         context;
} PixelSinkCallbacks;

// MARK: - PixelSinkPool C-ABI (pixel_sink_pool_*)

void*    pixel_sink_pool_create(void);
void     pixel_sink_pool_destroy(void* handle);
uint64_t pixel_sink_pool_register(void* handle, uint32_t stream, PixelSinkCallbacks cbs);
void     pixel_sink_pool_unregister(void* handle, uint64_t token);
void     pixel_sink_pool_dispatch(void* handle, uint32_t stream,
                                  uint64_t frameNumber, int64_t presentationTimeNs,
                                  void* surface);
unsigned pixel_sink_pool_consumer_count(void* handle, uint32_t stream);
uintptr_t pixel_sink_pool_raw_pointer(void* handle);

// MARK: - CaptureAtomic C-ABI (capture_atomic_*)

void* capture_atomic_create(void);
void  capture_atomic_destroy(void* handle);
bool  capture_atomic_try_acquire(void* handle);
void  capture_atomic_release(void* handle);

// MARK: - CannyStubConsumer C-ABI (canny_stub_*)

void*    canny_stub_create(void);
void     canny_stub_destroy(void* handle);
void     canny_stub_on_frame(void* context, uint32_t stream, uint64_t frameNumber,
                             int64_t presentationTimeNs, void* surface);
uint64_t canny_stub_processed_count(void* handle);
uint32_t canny_stub_edge_count(void* handle, size_t idx);

#ifdef __cplusplus
}
#endif
