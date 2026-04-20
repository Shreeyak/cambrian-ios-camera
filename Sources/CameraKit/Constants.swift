import Metal
import CoreVideo

enum Constants {
    static let frameRateTargetFPS: Int = 30
    static let capturePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let workingPixelFormat: MTLPixelFormat = .rgba16Float
    static let captureDefaultWidthPx: Int = 4160
    static let captureDefaultHeightPx: Int = 3120
    static let captureFallbackWidthPx: Int = 1280
    static let captureFallbackHeightPx: Int = 960
    static let cropDefaultWidthPx: Int = 1600
    static let cropDefaultHeightPx: Int = 1200
    static let captureOrientationAngleDeg: CGFloat = 90
    static let stateStreamBufferSize: Int = 64
}
