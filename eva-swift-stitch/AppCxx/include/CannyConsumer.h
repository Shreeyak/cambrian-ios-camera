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
