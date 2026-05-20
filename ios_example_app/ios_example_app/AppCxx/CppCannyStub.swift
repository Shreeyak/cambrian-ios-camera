// CppCannyStub — Swift wrapper over the AppCxx Canny consumer C-ABI.
// Phase 1B (2026-05-15) — relocated from
// CameraKit/Sources/CameraKitInterop/CameraKitInterop.swift.
// Class name + public API preserved so DisplayViewModel callsites are unchanged.
//
// The canny_stub_* C-ABI symbols come from AppCxx/CannyConsumer.cpp and are
// exposed to Swift via AppCxx-Bridging-Header.h (SWIFT_OBJC_BRIDGING_HEADER
// on the ios_example_app target).
import CameraKit  // PixelSinkCallbacks (Swift-side struct used by
                  // engine.consumers.registerCallback).
import Foundation
import OSLog

private let log = Logger(subsystem: "com.cambrian.camerakit", category: "appcxx")

/// OpenCV-backed Canny stub consumer (ring buffer of edge counts per ADR-29).
public final class CppCannyStub: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    public init() {
        guard let h = canny_stub_create() else {
            fatalError("canny_stub_create() returned null — out of memory or invalid heap state")
        }
        self.handle = h
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
