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
    // linear-normalization-stage: the fused per-channel normalization affine,
    // evaluated in LINEAR light BEFORE the gamma-space grade above. Per channel:
    //
    //     out = a · x + b
    //
    // THREE physically-distinct calibration ops collapse into this one multiply-add
    // (they are all per-channel linear ops, so they compose exactly — design D2):
    //
    //     • black point      → contributes to b   (an OFFSET; dark field → 0)
    //     • WB chroma residual → contributes to a (a per-channel GAIN; neutralizes cast)
    //     • white-point level  → contributes to a (a scalar GAIN; lifts white → target)
    //
    // with, on the HOST side (ColorUniform.init in MetalPipeline.swift — this shader
    // never sees the individual ops, only the folded a/b):
    //
    //     a = wbChroma · whitePointLevel      (per channel; level is a scalar)
    //     b = −a · blackPoint                 (so black is subtracted FIRST, then gained)
    //
    // Each op is gated by its own toggle host-side, substituting its identity value
    // when off (blackPoint→0, chroma→1, level→1); white-point level is additionally
    // gated by chroma (D4 — "level without chroma" is inert). All-off ⇒ a=1, b=0 and
    // `normalizeEnabled` is 0 so this block is skipped entirely (see the kernel).
    //
    // Individual scalars (NOT float3) so the host/shader byte layout is identical for
    // `setBytes` (no float3 16-byte alignment surprises).
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

// gradePixel — the ENTIRE pointwise color transform for ONE RGB triple, in
// registers. This is the single source of truth for the color pipeline math:
// both `colorTransform` (the standalone grade kernel, retained as a test seam)
// and the fused `yuvGradedFused` kernel below call this, so there is exactly one
// definition of "normalize → brightness → contrast → saturation → gamma".
//
// Input/output are gamma-encoded R'G'B' (the working/display space). Alpha is the
// caller's concern (this helper never touches it). The five steps run in the order
// fixed by the header (§Order); each has a documented identity point so an
// all-identity ColorUniform is a no-op (modulo the gated sRGB round-trip below).
static inline float3 gradePixel(float3 c, constant ColorUniform& u) {
    // 0. Linear-light normalization (linear-normalization-stage) — runs BEFORE the
    //    gamma-space grade below. Black point / WB chroma / white point are physical
    //    (multiply/subtract on light) and are only correct in LINEAR light, so this
    //    block is a four-step round trip — note the UNITS change at each arrow:
    //
    //      c (gamma R'G'B')  --srgbToLinear-->  lin (LINEAR)
    //                        --a·lin + b------>  lin (LINEAR, normalized)   ← the fused affine
    //                        --clamp[0,1]----->  lin (LINEAR, bounded)
    //                        --linearToSrgb--->  c   (gamma R'G'B')         ← back for the grade
    //
    //    `a`/`b` are the host-folded per-channel affine (see ColorUniform above:
    //    a = chroma·level, b = −a·blackPoint); this kernel applies them verbatim and
    //    knows nothing of the three ops that produced them.
    //
    //    Gated by `normalizeEnabled`: when no normalization op is active we skip the
    //    whole block, leaving `c` untouched. This is the real identity guarantee —
    //    the half-float sRGB round-trip is NOT bit-exact and BT.601 can hand us
    //    out-of-gamut values, so even a "no-op" (a=1,b=0) round-trip would perturb
    //    pixels. Host sets the gate iff black point OR chroma is on (an orphan white
    //    point is inert, so it must not trip the gate).
    if (u.normalizeEnabled != 0) {
        // gamma → linear (c is gamma-encoded R'G'B' from the BT.601 decode pass)
        float3 lin = float3(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b));
        // the fused per-channel affine, in LINEAR light: out = a·x + b
        lin = float3(u.aR, u.aG, u.aB) * lin + float3(u.bR, u.bG, u.bB);
        // Clamp to [0, 1]: the lower bound is MANDATORY (a black-point subtraction
        // drives near-black below 0, and linearToSrgb(neg) = NaN) and doubles as the
        // black floor; the upper bound is the white ceiling (white point maps the
        // reference to ≤ 1, and anything brighter clamps to solid white).
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

    return c;
}

// colorTransform — standalone grade kernel: read RGBA16F `natural`, grade,
// write RGBA16F `processed`. After the decode→grade→pack fusion
// (`yuvGradedFused`) this kernel is NO LONGER on the production frame path; it is
// retained because (a) the Stage-04 golden tests drive it via `encodeGradeOnly`
// to validate `gradePixel` in isolation, and (b) the fused-vs-separate
// equivalence test needs a reference grade. Because it shares `gradePixel` with
// the fused kernel, those golden tests transitively validate the fused grade.
kernel void colorTransform(texture2d<float, access::read>  inTex  [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant ColorUniform&          u      [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    float4 srgb = inTex.read(gid);
    outTex.write(float4(gradePixel(srgb.rgb, u), srgb.a), gid);
}

// ---------------------------------------------------------------------------
// Fused decode → grade → pack (kernel-fusion optimization)
// ---------------------------------------------------------------------------
//
// `CropUniform` and `decodeYuvBt601` are DUPLICATED from YUVToRGBA.metal. Metal
// compiles each .metal file as a separate translation unit, so a shared struct /
// helper would require a shared .h header — and a SwiftPM Metal build treats a
// stray header inconsistently, so we copy instead. KEEP IN SYNC with
// YUVToRGBA.metal: the byte layout of `CropUniform` and the BT.601 coefficients
// MUST match exactly. Two device tests guard against silent divergence by running
// the OLD `yuvToRgba`+`colorTransform` path and this fused kernel on the SAME
// input and asserting the outputs agree: `fusedVsSeparateCoreEquivalence` (chroma-
// rich input) catches BT.601 COEFFICIENT drift, and `fusedCropOriginMatchesSeparate`
// (spatially-varying input + non-zero, non-square crop origin) catches CROP-ORIGIN
// drift (e.g. a `gid.x + crop.originY` typo). Divergence fails a test, not ships.

// Mirrors struct CropUniform in YUVToRGBA.metal (and Swift `CropUniform`). The
// shader uses only originX/originY; width/height are carried for host layout parity.
struct CropUniform {
    uint originX;
    uint originY;
    uint width;
    uint height;
};

// BT.601 full-range YCbCr 4:2:0 → RGBA decode for ONE output pixel. `src` is the
// source pixel in the FULL capture frame (caller adds the crop origin), so this
// is a true 1:1 sub-region read (no zoom). Byte-for-byte the same math as
// `yuvToRgba` in YUVToRGBA.metal — see the KEEP IN SYNC note above.
static inline float4 decodeYuvBt601(
    texture2d<float, access::read> yTex,
    texture2d<float, access::read> cbcrTex,
    uint2 src)
{
    // Luma — full-range: Y already in [0, 1].
    float Y = yTex.read(src).r;
    // Chroma — 4:2:0: chroma plane is half-resolution in both dimensions.
    float2 UV = cbcrTex.read(uint2(src.x / 2, src.y / 2)).rg;
    // Center chroma around 0 (UV values from .rg8Unorm are [0, 1]).
    float Cb = UV.x - 0.5;
    float Cr = UV.y - 0.5;
    // BT.601 full-range matrix.
    float R = Y + 1.402   * Cr;
    float G = Y - 0.344136 * Cb - 0.714136 * Cr;
    float B = Y + 1.772   * Cb;
    return float4(R, G, B, 1.0);
}

// Compile-time variant switch: when false, the `packedTex` binding and the BGRA8
// write are dropped entirely (no bound texture required). The host builds two
// PSOs from this one source — one per value of kWritePacked (MetalPipeline.swift
// `yuvGradedFusedPackPSO` / `...NoPackPSO`).
constant bool kWritePacked [[function_constant(0)]];

// yuvGradedFused — the production frame core, fusing the former decode+grade+pack
// passes into one dispatch. It reads the YUV planes ONCE and produces its outputs
// from values held in registers, eliminating the two full-frame RGBA16F texture
// re-reads the old three-encoder path paid (decode wrote `natural`; grade re-read
// `natural`; pack re-read `processed`).
//
// THE TWO OUTPUTS — each is a live pipeline surface with a DISTINCT role; that is WHY
// they cannot collapse into one (a fresh reader's first question):
//   • naturalTex (RGBA16F) — the UN-graded decode, kept at 16F for linear-light
//                            precision. Calibration tap only (`_latestNaturalTex16F`):
//                            black-point / WB read it back. No streaming consumer.
//                            (optimization C gates this write to armed calibration.)
//   • packedTex  (BGRA8)   — the GRADED frame at 8-bit — the pipeline's SINGLE graded
//                            surface. Feeds ALL graded consumers: tracker (MPS/blit)
//                            source, processed-lane delivery mailbox (the normal
//                            format), AND the NV12 video recorder (which reads 8-bit
//                            `.rgb` and writes 8-bit YUV — the 16F processed texture
//                            the recorder used to read was retired, optimization B).
//                            Dropped when kWritePacked=false (no graded consumer this
//                            frame — no .tracker subscriber and no mailbox target;
//                            `grd` is then computed but unused).
//
// PER-THREAD DATA FLOW (one output pixel `gid`):
//
//     yTex,cbcrTex ──decodeYuvBt601(src)──▶ nat (float4, gamma R'G'B', f32 regs)
//                                            │
//                     naturalTex.write(nat) ◀┤   ← 16F natural (calibration tap;
//                                            │      also the decode reference)
//                          gradePixel(nat)  ─┘
//                                 │
//                                 ▼
//                          grd (float3, graded, f32 regs)
//                                 │
//                    if kWritePacked:        │
//         packedTex.write(clamp(grd,0,1)) ◀──┘   ← BGRA8 graded (tracker + delivery
//                                                   mailbox + NV12 recorder)
//
// PRECISION NOTE (why fused packed is ~1 LSB off the old separate path, NOT a bug):
//   old:  pack re-read `processed` FROM the rgba16Float texture → clamped the
//         16F-truncated grade, then quantized to 8-bit.
//   fused: clamps+quantizes the float32 REGISTER grade directly (no 16F round trip).
//         So `packedTex` differs from the old path by ≲ 1 LSB at 8-bit; `naturalTex`
//         is byte-identical (both store 16F(decode)). The equivalence test asserts
//         packed-vs-packed at ~5e-3 (8-bit) and natural-vs-natural at 1e-4.
//
// OUTPUT BINDINGS — both are WRITE-ONLY; neither is read back within the kernel, so
// there is no intra-kernel texture hazard (the grade reads the register `nat`, not
// `naturalTex`). Downstream passes (tracker + NV12 encode read `packedTex`) are
// separate encoders in the same command buffer, so Metal inserts the usual inter-pass
// barrier — same ordering the old path had.
kernel void yuvGradedFused(
    texture2d<float, access::read>  yTex       [[texture(0)]],
    texture2d<float, access::read>  cbcrTex    [[texture(1)]],
    texture2d<float, access::write> naturalTex [[texture(2)]],
    texture2d<float, access::write> packedTex  [[texture(3), function_constant(kWritePacked)]],
    constant CropUniform&           crop       [[buffer(0)]],
    constant ColorUniform&          color      [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Bounds guard on the output (crop-region) dims — extra tile threads may exceed it.
    if (gid.x >= naturalTex.get_width() || gid.y >= naturalTex.get_height()) {
        return;
    }

    // Map the output pixel to its source pixel in the full capture-resolution frame.
    uint2 src = uint2(gid.x + crop.originX, gid.y + crop.originY);

    // Decode once (float32 registers). Write the natural lane (16F) — the
    // calibration sampler input, and the byte-identical decode reference.
    float4 nat = decodeYuvBt601(yTex, cbcrTex, src);
    naturalTex.write(nat, gid);

    // Grade in registers from the f32 decode (see PRECISION NOTE), then pack to
    // BGRA8 — the SINGLE graded surface (tracker source, delivery mailbox, and the
    // NV12 recorder all read this now). clamp[0,1] matches the old rgba16fToBgra8
    // kernel (a bgra8Unorm write clamps anyway; explicit for parity). Dropped in the
    // no-pack variant (no graded consumer this frame — grd is then unused).
    float3 grd = gradePixel(nat.rgb, color);
    if (kWritePacked) {
        packedTex.write(clamp(float4(grd, nat.a), 0.0, 1.0), gid);
    }
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
