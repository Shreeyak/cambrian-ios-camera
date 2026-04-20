#include <metal_stdlib>
using namespace metal;

// BT.601 full-range YCbCr 4:2:0 → RGBA16F conversion.
//
// Input:
//   yTex    — luma plane, .r8Unorm (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
//             Y is mapped 0–255 → 0.0–1.0 by the GPU; no video-range offset needed.
//   cbcrTex — chroma plane, .rg8Unorm, half-width × half-height (4:2:0 subsampling)
//             Cb in .r, Cr in .g, each mapped 0–255 → 0.0–1.0 by the GPU.
// Output:
//   outTex  — .rgba16Float
kernel void yuvToRgba(texture2d<float, access::read>  yTex    [[texture(0)]],
                      texture2d<float, access::read>  cbcrTex [[texture(1)]],
                      texture2d<float, access::write> outTex  [[texture(2)]],
                      uint2 gid [[thread_position_in_grid]])
{
    // Bounds guard — extra threads dispatched to fill a tile may exceed texture size.
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    // Sample luma — full-range: Y already in [0, 1].
    float Y = yTex.read(gid).r;

    // Sample chroma — 4:2:0: chroma plane is half-resolution in both dimensions.
    float2 UV = cbcrTex.read(uint2(gid.x / 2, gid.y / 2)).rg;

    // Center chroma around 0 (UV values from .rg8Unorm are [0, 1]).
    float Cb = UV.x - 0.5;
    float Cr = UV.y - 0.5;

    // BT.601 full-range matrix.
    float R = Y + 1.402   * Cr;
    float G = Y - 0.344136 * Cb - 0.714136 * Cr;
    float B = Y + 1.772   * Cb;

    outTex.write(float4(R, G, B, 1.0), gid);
}
