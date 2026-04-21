#include <metal_stdlib>
using namespace metal;

// Stage 04 — color-transform compute kernel operating in RGBA16F.
//
// Order per architecture/07-settings.md §Processing order:
//   1. Black balance  (subtract per channel, clamp ≥ 0)
//   2. Brightness     (positive: power curve; negative: linear scale)
//   3. Contrast       (linear around 0.5 midpoint)
//   4. Saturation     (luma-based mix, COLOR_LUMA_WEIGHT R/G/B per G-18)
//   5. Gamma          (pow(x, 1/gamma))
//
// Identity when ColorUniform = { brightness:0, contrast:1, saturation:0,
// blackR:0, blackG:0, blackB:0, gamma:1 } — verified per channel below.
//
// scaffolding:01:simple-metal-passthrough — Pass 2 only; Pass 3/4/5/6 arrive
// in later stages.

struct ColorUniform {
    float brightness;
    float contrast;
    float saturation;
    float blackR;
    float blackG;
    float blackB;
    float gamma;
};

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

    // 1. Black balance — subtract per channel, clamp at 0.
    c.r = max(0.0, c.r - u.blackR);
    c.g = max(0.0, c.g - u.blackG);
    c.b = max(0.0, c.b - u.blackB);

    // 2. Brightness — positive: gamma-style boost; negative: linear scale.
    //    At brightness=0, exponent=1 and scale=1 → identity in both branches.
    if (u.brightness >= 0.0) {
        float exponent = 1.0 / (1.0 + u.brightness);
        c = pow(max(c, 0.0), float3(exponent));
    } else {
        c = c * (1.0 + u.brightness);
    }

    // 3. Contrast — centered linear scale around 0.5. At contrast=1 → identity.
    c = (c - 0.5) * u.contrast + 0.5;

    // 4. Saturation — luma-based mix. At saturation=0, mix factor = 1 → identity.
    //    saturation = -1.0 → fully desaturated (grayscale).
    float luma = dot(c, COLOR_LUMA_WEIGHT);
    c = mix(float3(luma), c, 1.0 + u.saturation);

    // 5. Gamma — power law. At gamma=1, exponent=1 → identity.
    //    Guard against divide-by-zero: shader spec assumes gamma > 0; clamp
    //    defensively in case host passes a stale 0 from an uninitialised slider.
    float safeGamma = max(u.gamma, 1e-3);
    c = pow(max(c, 0.0), float3(1.0 / safeGamma));

    outTex.write(float4(c, srgb.a), gid);
}
