import CoreGraphics
import Foundation

// MARK: - Core geometry types

public struct Size: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Session capabilities

/// A capture resolution paired with a frame-rate range it supports.
///
/// One entry per (size, `videoSupportedFrameRateRanges` range) the device offers as a
/// full-range 420f format, so a size can appear more than once — e.g. a full-FOV
/// `1–60` range and a binned slow-mo `2–240` range at the same dimensions
/// (configurable-frame-rate). `minFps`/`maxFps` are the inclusive integer bounds a
/// caller may pass as `OpenConfiguration.targetFps` for that resolution.
public struct FrameRateRange: Sendable, Hashable {
    public let size: Size
    public let minFps: Int
    public let maxFps: Int

    public init(size: Size, minFps: Int, maxFps: Int) {
        self.size = size
        self.minFps = minFps
        self.maxFps = maxFps
    }
}

/// Returned by CameraEngine.open(configuration:) per domain-revised/10-api-contract.md §SessionCapabilities.
public struct SessionCapabilities: Sendable, Hashable {
    public let supportedSizes: [Size]
    /// Frame-rate ranges supported per resolution, live from the device's 420f formats.
    ///
    /// Includes slow-mo where offered. A caller reads this to pick a valid
    /// `(captureResolution, targetFps)` before `open()`. See `FrameRateRange`.
    public let supportedFrameRates: [FrameRateRange]
    /// The frame rate the session is locked to (the resolved `OpenConfiguration.targetFps`).
    public let activeFrameRate: Int
    // flutter-single-preview: `previewTextureId` (and earlier `naturalTextureId`,
    // in remove-natural-lane) were removed — dead Stage-05 stubs, always 0, with
    // no value-reader. Preview textures are allocated on demand via
    // `createPreviewTexture(stream:)`, so `SessionCapabilities` carries no preview
    // texture id on either the Swift or Pigeon contract.
    public let activeCaptureResolution: Size
    public let activeCropRegion: Rect
    /// Pixel format string of the *lane buffer* returned by
    /// `currentPixelBuffer(stream:)` — what the Phase-3 zero-copy texture
    /// bridge sees.
    ///
    /// Always `"BGRA8"` (`kCVPixelFormatType_32BGRA`, `.bgra8Unorm`) — Apple's
    /// `CVMetalTextureCache`-canonical 32-bit RGBA-family format on iOS, and the
    /// single delivery format for every lane and every surface type. The
    /// **texture accessors** — `currentProcessedTexture()`,
    /// `currentTrackerTexture()` — return the same BGRA8 IOSurface as the
    /// matching `currentPixelBuffer(stream:)`. RGBA16F survives only as an
    /// internal Metal-compute intermediate (the camera is 8-bit-locked, so
    /// float precision buys nothing at the boundary).
    ///
    /// Note this is **not** the camera *source* format (YUV `420f`, converted
    /// by MetalPipeline Pass-1).
    public let streamPixelFormat: String
    public let isoRange: ClosedRange<Float>
    public let exposureDurationRangeNs: ClosedRange<Int64>
    /// Lens-position range — always `0.0...1.0` on iOS.
    ///
    /// `AVCaptureDevice.lensPosition` is normalized, not real diopters. Kept
    /// for shape parity with the Pigeon contract's `focusMin`/`focusMax`.
    /// Phase-2 design §2c.
    public let focusRange: ClosedRange<Double>
    /// `AVCaptureDevice.minAvailableVideoZoomFactor` ... `maxAvailableVideoZoomFactor`.
    ///
    /// Returned for the active format. Phase-2 design §2c.
    public let zoomRange: ClosedRange<Double>
    /// `AVCaptureDevice.minExposureTargetBias` ... `maxExposureTargetBias`.
    ///
    /// Reported in EV stops (signed). Phase-2 design §2c.
    public let evCompensationRange: ClosedRange<Float>
    /// Effective (clamped and even-rounded) tracker lane resolution.
    ///
    /// Derived from `OpenConfiguration.trackerHeight` (height-driven, aspect-preserved against
    /// the primary output size, clamped `2…primaryHeight`, rounded to even). When
    /// `trackerHeight == primaryHeight`, this equals `activeCaptureResolution` and the tracker
    /// is produced by a 1:1 copy with no resampling.
    public let trackerResolution: Size

    public init(
        supportedSizes: [Size],
        supportedFrameRates: [FrameRateRange] = [],
        activeFrameRate: Int = 30,  // Constants.frameRateTargetFPS (internal); test-constructor default
        activeCaptureResolution: Size,
        activeCropRegion: Rect,
        streamPixelFormat: String,
        isoRange: ClosedRange<Float>,
        exposureDurationRangeNs: ClosedRange<Int64>,
        focusRange: ClosedRange<Double>,
        zoomRange: ClosedRange<Double>,
        evCompensationRange: ClosedRange<Float>,
        trackerResolution: Size
    ) {
        self.supportedSizes = supportedSizes
        self.supportedFrameRates = supportedFrameRates
        self.activeFrameRate = activeFrameRate
        self.activeCaptureResolution = activeCaptureResolution
        self.activeCropRegion = activeCropRegion
        self.streamPixelFormat = streamPixelFormat
        self.isoRange = isoRange
        self.exposureDurationRangeNs = exposureDurationRangeNs
        self.focusRange = focusRange
        self.zoomRange = zoomRange
        self.evCompensationRange = evCompensationRange
        self.trackerResolution = trackerResolution
    }
}

/// Startup arguments for CameraEngine.open(configuration:).
public struct OpenConfiguration: Sendable, Hashable {
    public var cameraId: String?
    public var captureResolution: Size?
    public var cropRegion: Rect?

    /// Whether the output is cropped at open.
    ///
    /// Separates crop *policy* from *geometry* (camera-crop-config). When
    /// `cropRegion` is set, that rect is the configured crop and is applied
    /// regardless of this flag. When `cropRegion` is `nil` and this is `true`, a
    /// centered `Constants.cropDefault*` (1440×1440) crop, clamped to the active
    /// capture resolution, is applied so the first delivered frame is already
    /// cropped (no full-frame-then-crop transition). Defaults to `false`
    /// (full-frame output).
    public var cropEnabled: Bool

    /// Target capture frame rate, locked in every mode (preview / still / recording).
    ///
    /// `nil` resolves to `Constants.frameRateTargetFPS` (30). Any integer is accepted
    /// but is validated at `open()` against the selected resolution's live
    /// `videoSupportedFrameRateRanges` — an unsupported `(captureResolution, targetFps)`
    /// pair throws `EngineError.settingsConflict` naming the frame rates valid for that
    /// resolution (the valid set is discoverable via `SessionCapabilities`, including
    /// slow-mo rates where a binned format supports them). Frame rate and resolution are
    /// independent: choosing a lower `targetFps` does not enlarge the default resolution.
    /// Because a frame's exposure cannot exceed its frame duration, `targetFps` also caps
    /// the max usable manual exposure at `1/targetFps`; open at a lower `targetFps` for
    /// longer exposures. Open-time only — change it by close + reopen.
    public var targetFps: Int?
    /// Hardware settings to apply during session setup, before the first frame
    /// is delivered.
    ///
    /// Folds the Pigeon contract's `open(cameraId, settings)` shape into
    /// CameraKit's structural `OpenConfiguration` so the requested settings are
    /// live from frame one (no defaults-then-snap flicker). Phase-2 design
    /// §2a. Applied via the same `updateSettings` merge+coupling+commit path
    /// after `setupSession` returns and before the first `startRunning`.
    public var initialSettings: CameraSettings?

    /// Target height (px) of the downsampled `tracker` lane.
    ///
    /// The tracker width is derived to preserve the output (processed) lane's
    /// aspect ratio — the two lanes must share an aspect so a motion vector
    /// measured on the tracker scales linearly to the processed frame. `nil` uses
    /// the package default (`Constants.trackerHeightPx`). Clamped to
    /// `2 ... outputHeight` (the lane is a downsample, never an upscale) and
    /// rounded down to an even value.
    public var trackerHeight: Int?

    /// Capture-buffer rotation in degrees, applied to the video/photo connections
    /// via `videoRotationAngle` (ADR-17).
    ///
    /// This rotates the *delivered pixel buffers* themselves, so every lane
    /// (preview, processed, tracker) and stills inherit it consistently. Valid
    /// values are `0` / `90` / `180` / `270`; an unsupported angle throws at
    /// `open()`. Defaults to `Constants.captureOrientationAngleDeg` (`0`, the
    /// package's landscape-right convention) — leave it unset and existing
    /// consumers are unaffected. A host that locks its UI to landscape-left, for
    /// example, passes `180` so the delivered frame reads upright.
    public var captureOrientationAngleDeg: CGFloat

    public init(
        cameraId: String? = nil,
        captureResolution: Size? = nil,
        targetFps: Int? = nil,
        cropRegion: Rect? = nil,
        cropEnabled: Bool = false,
        initialSettings: CameraSettings? = nil,
        trackerHeight: Int? = nil,
        captureOrientationAngleDeg: CGFloat = 0  // Constants.captureOrientationAngleDeg (internal); 0 = landscape-right
    ) {
        self.cameraId = cameraId
        self.captureResolution = captureResolution
        self.targetFps = targetFps
        self.cropRegion = cropRegion
        self.cropEnabled = cropEnabled
        self.initialSettings = initialSettings
        self.trackerHeight = trackerHeight
        self.captureOrientationAngleDeg = captureOrientationAngleDeg
    }
}

// MARK: - Settings types (compressed here per Stage 01 type-compression decision)

public enum CameraMode: String, Sendable, Hashable, Codable {
    case auto
    case manual
}

public enum WhiteBalanceMode: String, Sendable, Hashable, Codable {
    case auto
    case locked
    case manual
}

/// Apple's named WB temperature/tint presets.
///
/// Each case maps 1:1 to `AVCaptureDevice.WhiteBalanceTemperatureAndTintValues`
/// static properties (iOS 26.0+). Underlying Kelvin/tint values are
/// sensor-calibrated and not published by Apple.
public enum WhiteBalancePreset: String, Sendable, Hashable {
    case daylight
    case cloudy
    case shadow
    case tungsten
    case fluorescent
}

/// Partial-update settings object.
///
/// Per domain-revised/10-api-contract.md §CameraSettings.
/// Every field is optional; null = "do not change." Full merge logic arrives Stage 03.
public struct CameraSettings: Sendable, Hashable, Codable {
    public var isoMode: CameraMode?
    public var iso: Int?
    public var exposureMode: CameraMode?
    public var exposureTimeNs: Int64?
    public var focusMode: CameraMode?
    public var focusDistance: Double?
    public var wbMode: WhiteBalanceMode?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?
    public var zoomRatio: Double?
    public var evCompensation: Int?

    public init(
        isoMode: CameraMode? = nil,
        iso: Int? = nil,
        exposureMode: CameraMode? = nil,
        exposureTimeNs: Int64? = nil,
        focusMode: CameraMode? = nil,
        focusDistance: Double? = nil,
        wbMode: WhiteBalanceMode? = nil,
        wbGainR: Double? = nil,
        wbGainG: Double? = nil,
        wbGainB: Double? = nil,
        zoomRatio: Double? = nil,
        evCompensation: Int? = nil
    ) {
        self.isoMode = isoMode
        self.iso = iso
        self.exposureMode = exposureMode
        self.exposureTimeNs = exposureTimeNs
        self.focusMode = focusMode
        self.focusDistance = focusDistance
        self.wbMode = wbMode
        self.wbGainR = wbGainR
        self.wbGainG = wbGainG
        self.wbGainB = wbGainB
        self.zoomRatio = zoomRatio
        self.evCompensation = evCompensation
    }
}

/// GPU color-processing shader parameters.
///
/// All fields required. Full implementation Stage 04; linear-light normalization
/// fields added in linear-normalization-stage.
public struct ProcessingParameters: Sendable, Hashable, Codable {
    public var brightness: Double
    /// Contrast adjustment in `[-1, 1]`, `0.0` = identity.
    ///
    /// Linear scale around the 0.5 luma midpoint via a `1 + contrast` multiplier:
    /// `-1.0` = fully flat grey, `+1.0` = 2× contrast. Shares the `[-1, 1]` /
    /// `0.0`-identity convention with `brightness` and `saturation`. See
    /// `Shaders/ColorShaders.metal`.
    public var contrast: Double
    public var saturation: Double
    public var gamma: Double

    // MARK: - linear-normalization-stage (applied in linear light, pre-grade)

    /// Per-channel linear black point that offsets dark values toward 0 (identity `0`).
    ///
    /// Folded into the normalization affine `b` term when `blackPointEnabled`.
    /// Derived statistically (`mean + blackPointSigmaK·σ`) from a dark field.
    public var blackPointR: Double
    public var blackPointG: Double
    public var blackPointB: Double
    public var blackPointEnabled: Bool

    /// Per-channel white-balance chroma residual gain (identity `1`).
    ///
    /// Brightness-preserving cast neutralization applied on top of the locked
    /// hardware gains; gated to manual WB mode (identity in auto — enforced by
    /// `CameraEngine`, so the stored value is always "effective"). Folded into
    /// the affine `a` term when `wbChromaEnabled`.
    public var wbChromaR: Double
    public var wbChromaG: Double
    public var wbChromaB: Double
    public var wbChromaEnabled: Bool

    /// Scalar white-point level lifting the neutralized white reference to the
    /// configured target `Constants.whitePointTargetDisplay` (identity `1`).
    ///
    /// Separate, optional, off by default (phase-contrast grey must not be
    /// stretched). Only valid alongside `wbChroma`; folded into the affine `a`.
    public var whitePointLevel: Double
    public var whitePointEnabled: Bool

    public init(
        brightness: Double = 0.0,
        contrast: Double = 0.0,
        saturation: Double = 0.0,
        gamma: Double = 1.0,
        blackPointR: Double = 0.0,
        blackPointG: Double = 0.0,
        blackPointB: Double = 0.0,
        blackPointEnabled: Bool = false,
        wbChromaR: Double = 1.0,
        wbChromaG: Double = 1.0,
        wbChromaB: Double = 1.0,
        wbChromaEnabled: Bool = false,
        whitePointLevel: Double = 1.0,
        whitePointEnabled: Bool = false
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.blackPointR = blackPointR
        self.blackPointG = blackPointG
        self.blackPointB = blackPointB
        self.blackPointEnabled = blackPointEnabled
        self.wbChromaR = wbChromaR
        self.wbChromaG = wbChromaG
        self.wbChromaB = wbChromaB
        self.wbChromaEnabled = wbChromaEnabled
        self.whitePointLevel = whitePointLevel
        self.whitePointEnabled = whitePointEnabled
    }

    public static let identity = ProcessingParameters()

    // MARK: - Back-compatible decoding (linear-normalization-stage)

    private enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, gamma
        case blackPointR, blackPointG, blackPointB, blackPointEnabled
        case wbChromaR, wbChromaG, wbChromaB, wbChromaEnabled
        case whitePointLevel, whitePointEnabled
    }

    /// Migration-safe decode: old `…v2` blobs predate the normalization fields,
    /// and Swift's synthesized `Decodable` throws on missing keys.
    ///
    /// Decoding every field via `decodeIfPresent` with the identity default keeps
    /// persisted brightness/contrast/saturation/gamma *values* (so settings don't
    /// reset) while normalization fields default to identity/disabled. This does
    /// NOT preserve the old operation order: the order is linear normalization
    /// (WB / white point / black point) then the gamma-space grade. Legacy
    /// `blackR/G/B` keys in old blobs are ignored (the legacy black-balance was
    /// removed — a breaking change); the linear black point is recalibrated fresh.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProcessingParameters.identity
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? d.contrast
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? d.saturation
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? d.gamma
        blackPointR = try c.decodeIfPresent(Double.self, forKey: .blackPointR) ?? d.blackPointR
        blackPointG = try c.decodeIfPresent(Double.self, forKey: .blackPointG) ?? d.blackPointG
        blackPointB = try c.decodeIfPresent(Double.self, forKey: .blackPointB) ?? d.blackPointB
        blackPointEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .blackPointEnabled) ?? d.blackPointEnabled
        wbChromaR = try c.decodeIfPresent(Double.self, forKey: .wbChromaR) ?? d.wbChromaR
        wbChromaG = try c.decodeIfPresent(Double.self, forKey: .wbChromaG) ?? d.wbChromaG
        wbChromaB = try c.decodeIfPresent(Double.self, forKey: .wbChromaB) ?? d.wbChromaB
        wbChromaEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .wbChromaEnabled) ?? d.wbChromaEnabled
        whitePointLevel =
            try c.decodeIfPresent(Double.self, forKey: .whitePointLevel) ?? d.whitePointLevel
        whitePointEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .whitePointEnabled) ?? d.whitePointEnabled
    }
}
