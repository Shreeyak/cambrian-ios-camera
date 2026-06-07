import CoreVideo

/// The single pixel currency on both sides of the transport.
///
/// A class, not a struct, because it must release its underlying lock on
/// `deinit` — structs have no deinit. `@unchecked Sendable` is the sanctioned
/// raw-pointer case: ``baseAddress`` is immutable after init; the GPU/decoder
/// finished writing before delivery (single-writer); concurrent read-only
/// consumers of the immutable buffer are safe. A bounded hold beyond the
/// delivering call is permitted — the lease keeps the pixels valid for the
/// lifetime of the held reference.
public final class PixelHandle: @unchecked Sendable {
    /// Pointer to the first byte of the locked pixel buffer.
    public let baseAddress: UnsafeRawPointer
    /// Pixel width.
    public let width: Int
    /// Pixel height.
    public let height: Int
    /// The REAL row stride in bytes — never an assumed `width * 4`.
    ///
    /// For an IOSurface-backed buffer this is the padded stride reported by the
    /// surface, which kills the `width * 4` corruption bug at its root.
    public let bytesPerRow: Int
    /// The pixel layout `baseAddress` points at.
    public let format: PixelFormat

    // Called once on deinit to unlock + release the backing buffer (return the
    // pool slot). Not `@Sendable`: it captures a non-Sendable CVPixelBuffer, and
    // the enclosing class is already `@unchecked Sendable`.
    private let onRelease: (() -> Void)?

    /// Wraps an already-locked region with an explicit release hook.
    ///
    /// The generic entry point used by non-CVPixelBuffer sources (file /
    /// synthetic) and by tests. `release` is invoked exactly once on `deinit`.
    public init(
        baseAddress: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        format: PixelFormat,
        release: (() -> Void)? = nil
    ) {
        self.baseAddress = baseAddress
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.format = format
        self.onRelease = release
    }

    /// Locks a `CVPixelBuffer`, retains it for the handle's lifetime, and
    /// releases the lock on `deinit`.
    ///
    /// Returns `nil` if the buffer cannot be locked or exposes no base address.
    /// Dimensions and `bytesPerRow` are read from the buffer, so the stride is
    /// always the surface's real (possibly padded) stride.
    ///
    /// The caller asserts that `format` matches the buffer's actual pixel
    /// format; it is not validated. Planar buffers are unsupported —
    /// `CVPixelBufferGetBaseAddress` returns nil for them, so this returns nil.
    public convenience init?(
        pixelBuffer: CVPixelBuffer,
        format: PixelFormat,
        lockFlags: CVPixelBufferLockFlags = .readOnly
    ) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess
        else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags)
            return nil
        }
        self.init(
            baseAddress: UnsafeRawPointer(base),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            format: format,
            // Capturing `pixelBuffer` retains it (ARC) until the handle dies.
            release: { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }
        )
    }

    deinit { onRelease?() }
}
