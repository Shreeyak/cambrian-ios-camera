#include <metal_stdlib>
using namespace metal;

// Stage 04 — color-transform compute kernel operating in RGBA16F.
//
// Order (user-directed; overrides architecture/07-settings.md §Processing order
// — see CameraKit/state.md "Decisions taken that weren't in briefs"):
//   0. Normalization  (linear-normalization-stage) — in LINEAR light, pre-grade:
//                      linearize → fused per-channel affine (a·x+b) → re-encode.
//                      Gated by `normalizeEnabled`; identity/skipped when off.
//   1. Brightness     (positive: power curve; negative: linear scale)
//   2. Contrast       (linear scale around 0.5 midpoint, multiplier 1+contrast)
//   3. Saturation     (luma-based mix, COLOR_LUMA_WEIGHT R/G/B per G-18)
//   4. Gamma          (pow(x, 1/gamma))
//
// Contrast/brightness/saturation share one [-1,1] convention with 0.0 = identity
// (contrast uses a 1+contrast multiplier, structurally identical to saturation's
// 1+saturation mix factor). Identity when ColorUniform = { brightness:0,
// contrast:0, saturation:0, gamma:1 }.
//
struct ColorUniform {
    float brightness;
    float contrast;
    float saturation;
    float gamma;
    // linear-normalization-stage: fused per-channel affine in LINEAR light,
    // applied BEFORE the gamma-space grade above. `out = a·x + b` per channel.
    // Identity (a=1, b=0) ⇒ no-op. Individual scalars (NOT float3) to keep the
    // host/shader byte layout identical for setBytes. Applied in task 2.2.
    float aR;
    float aG;
    float aB;
    float bR;
    float bG;
    float bB;
    uint  transferFn;       // 0 = sRGB (default / fallback when no buffer attachment)
    uint  normalizeEnabled; // 0 = skip the whole normalization block (off-path identity)
};

// sRGB transfer functions (IEC 61966-2-1), used to move between gamma-encoded
// display values and linear light for the normalization affine.
//
// These are the TRUE piecewise curves, NOT a pow(2.2) approximation. The split
// matters here: the black point operates in the near-black region, which is
// exactly where the linear segment (x ≤ ~0.04 → x/12.92) and a pure power curve
// diverge most. A pow(2.2) shortcut would land calibrated black at the wrong
// linear value, so "solid black" would not come out solid.
static inline float srgbToLinear(float c) {
    // gamma → linear (decode / EOTF)
    return (c <= 0.04045f) ? (c / 12.92f) : pow((c + 0.055f) / 1.055f, 2.4f);
}
static inline float linearToSrgb(float c) {
    // linear → gamma (encode / OETF). Caller MUST clamp c ≥ 0 first:
    // pow(negative, 1/2.4) is NaN, and black subtraction produces negatives.
    return (c <= 0.0031308f) ? (c * 12.92f) : (1.055f * pow(c, 1.0f / 2.4f) - 0.055f);
}

// BT.709 luma coefficients in RGBA channel order (G-18: never apply BGRA
// coefficients to RGBA buffers).
constant float3 COLOR_LUMA_WEIGHT = float3(0.2126, 0.7152, 0.0722);

kernel void colorTransform(texture2d<float, access::read>  inTex  [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant ColorUniform&          u      [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    float4 srgb = inTex.read(gid);
    float3 c = srgb.rgb;

    // 0. Linear-light normalization (linear-normalization-stage) — runs BEFORE the
    //    gamma-space grade below. Physical ops (black point, white balance, white
    //    point) are only correct in linear light, so we: undo gamma → apply one
    //    fused per-channel affine in linear → re-encode to gamma → then grade.
    //
    //    Gated by `normalizeEnabled`: when no normalization op is active we skip the
    //    whole block, leaving `c` untouched. This is the real identity guarantee —
    //    the half-float sRGB round-trip is NOT bit-exact and BT.601 can hand us
    //    out-of-gamut values, so a "no-op" round-trip would still perturb pixels.
    //
    //    The affine is `out = a·x + b` in linear, where (host-computed, ColorUniform):
    //      a = wbChroma · whitePointLevel   (per-channel gain; level is scalar)
    //      b = −a · blackPoint              (black subtracted first, then gained)
    if (u.normalizeEnabled != 0) {
        // gamma → linear (c is gamma-encoded R'G'B' from the BT.601 decode pass)
        float3 lin = float3(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b));
        // fused per-channel affine in LINEAR light
        lin = float3(u.aR, u.aG, u.aB) * lin + float3(u.bR, u.bG, u.bB);
        // Clamp to [0, 1]: lower bound is mandatory (black subtraction makes
        // negatives; linearToSrgb(neg) = NaN) and is the black floor; upper bound
        // is the white ceiling (white point maps the reference to ≤ 1, brighter
        // values clamp to solid white).
        lin = clamp(lin, 0.0, 1.0);
        // linear → gamma, back into the working/display space for the grade below
        c = float3(linearToSrgb(lin.r), linearToSrgb(lin.g), linearToSrgb(lin.b));
    }

    // 1. Brightness — positive: gamma-style boost; negative: linear scale.
    //    At brightness=0, exponent=1 and scale=1 → identity in both branches.
    if (u.brightness >= 0.0) {
        float exponent = 1.0 / (1.0 + u.brightness);
        c = pow(max(c, 0.0), float3(exponent));
    } else {
        c = c * (1.0 + u.brightness);
    }

    // 2. Contrast — centered linear scale around 0.5 via a 1+contrast multiplier.
    //    At contrast=0 → identity; -1 → fully flat grey; +1 → 2x contrast. Matches
    //    the [-1,1] convention of brightness/saturation (see header).
    c = (c - 0.5) * (1.0 + u.contrast) + 0.5;

    // 3. Saturation — luma-based mix. At saturation=0, mix factor = 1 → identity.
    //    saturation = -1.0 → fully desaturated (grayscale).
    float luma = dot(c, COLOR_LUMA_WEIGHT);
    c = mix(float3(luma), c, 1.0 + u.saturation);

    // 4. Gamma — power law. At gamma=1, exponent=1 → identity.
    //    Guard against divide-by-zero: shader spec assumes gamma > 0; clamp
    //    defensively in case host passes a stale 0 from an uninitialised slider.
    float safeGamma = max(u.gamma, 1e-3);
    c = pow(max(c, 0.0), float3(1.0 / safeGamma));

    outTex.write(float4(c, srgb.a), gid);
}

// Copies the centered `dst`-sized square window of `src` into `dst`, so
// black-point calibration can read back only the sampled neighborhood (the
// center patch plus its surrounding context) instead of the full
// multi-megapixel frame. `dst` is square and centered on `src`'s geometric
// center. This is a kernel *read* at an offset (not a blit), so it is safe on
// the IOSurface-backed lane textures regardless of the offset.
kernel void extractCenterRegion(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint sw = dst.get_width();
    uint sh = dst.get_height();
    if (gid.x >= sw || gid.y >= sh) {
        return;
    }
    int cx = int(src.get_width()) / 2;
    int cy = int(src.get_height()) / 2;
    int sx = clamp(cx - int(sw) / 2 + int(gid.x), 0, int(src.get_width()) - 1);
    int sy = clamp(cy - int(sh) / 2 + int(gid.y), 0, int(src.get_height()) - 1);
    dst.write(src.read(uint2(uint(sx), uint(sy))), gid);
}
