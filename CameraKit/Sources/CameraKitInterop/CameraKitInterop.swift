import CameraKitCxx
// CameraKitInterop — thin Swift module isolating C++ interop per ADR-13.
// .interoperabilityMode(.Cxx) is confined to this target only.
import Foundation
import OSLog

private let log = Logger(subsystem: "com.cambrian.camerakit", category: "interop")

// MARK: - CppPixelSinkPool

/// Wraps the C++ `PixelSinkPool` with a Swift-friendly reference type.
public final class CppPixelSinkPool: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    public init() {
        handle = pixel_sink_pool_create()!
        let ptr = pixel_sink_pool_raw_pointer(handle)
        log.info("CppPixelSinkPool: created — handle 0x\(String(ptr, radix: 16))")
    }

    deinit {
        log.info("CppPixelSinkPool: destroying")
        pixel_sink_pool_destroy(handle)
    }

    public func register(stream: UInt32, callbacks: CppPixelSinkCallbacks) -> UInt64 {
        pixel_sink_pool_register(handle, stream, callbacks.raw)
    }

    public func unregister(token: UInt64) {
        pixel_sink_pool_unregister(handle, token)
    }

    public func dispatch(
        stream: UInt32, frameNumber: UInt64,
        presentationTimeNs: Int64,
        surface: UnsafeMutableRawPointer?
    ) {
        pixel_sink_pool_dispatch(handle, stream, frameNumber, presentationTimeNs, surface)
    }

    public func consumerCount(stream: UInt32) -> UInt32 {
        pixel_sink_pool_consumer_count(handle, stream)
    }

    public func rawPointer() -> UInt64 {
        UInt64(pixel_sink_pool_raw_pointer(handle))
    }
}

// MARK: - CppPixelSinkCallbacks

/// Lightweight bridge type carrying the C-ABI callback struct.
public struct CppPixelSinkCallbacks: @unchecked Sendable {
    let raw: PixelSinkCallbacks

    public init(
        onFrame:
            @escaping @convention(c) (
                UnsafeMutableRawPointer?, UInt32, UInt64, Int64,
                UnsafeMutableRawPointer?
            ) -> Void,
        onOverwrite:
            @escaping @convention(c) (
                UnsafeMutableRawPointer?, UInt32
            ) -> Void,
        onError:
            @escaping @convention(c) (
                UnsafeMutableRawPointer?, Int32
            ) -> Void,
        context: UnsafeMutableRawPointer?
    ) {
        raw = PixelSinkCallbacks(
            on_frame: onFrame,
            on_overwrite: onOverwrite,
            on_error: onError,
            context: context)
    }
}

// MARK: - CppCaptureAtomic

/// Wraps the C++ `std::atomic<bool>` capture-in-flight guard (Invariant 7).
public final class CppCaptureAtomic: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    public init() { handle = capture_atomic_create()! }

    deinit { capture_atomic_destroy(handle) }

    /// CAS false → true.
    ///
    /// Returns true if acquired (was false, now true).
    public func tryAcquire() -> Bool { capture_atomic_try_acquire(handle) }

    /// Store false unconditionally.
    public func release() { capture_atomic_release(handle) }
}

// MARK: - CppCannyStub

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

    // Edge pixel count at ring-buffer index idx (0 ..< 64) for debug overlay.
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

    /// Returns the C-ABI on_frame function pointer for use with `PixelSinkCallbacks`.
    public func onFrameCallback()
        -> @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt64, Int64, UnsafeMutableRawPointer?) -> Void
    {
        { ctx, stream, frame, ts, surface in canny_stub_on_frame(ctx, stream, frame, ts, surface) }
    }

    /// Opaque C++ handle for use as the `context` field of `PixelSinkCallbacks`.
    public var nativeContext: UnsafeMutableRawPointer? { handle }
}
