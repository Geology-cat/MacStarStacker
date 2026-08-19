#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────
//  Metal Kernel: Pixel-accumulate images
//  Each invocation handles one texel (x, y).
//  The result is accumulated into a float4 buffer.
// ─────────────────────────────────────────────

kernel void accumulate(
    texture2d<float, access::read>  src      [[texture(0)]],
    device        float4           *dst      [[buffer(0)]],
    constant      uint             &width    [[buffer(1)]],
    uint2                           gid      [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 pixel = src.read(gid);
    uint index = gid.y * width + gid.x;
    dst[index] += pixel;
}

// ─────────────────────────────────────────────
//  Metal Kernel: Divide accumulated buffer by N
//  to produce the final averaged result.
// ─────────────────────────────────────────────

kernel void divideByCount(
    device       float4 *buffer    [[buffer(0)]],
    constant     float  &count     [[buffer(1)]],
    constant     uint   &total     [[buffer(2)]],
    uint                gid        [[thread_position_in_grid]])
{
    if (gid >= total) return;
    buffer[gid] = buffer[gid] / count;
}

// ─────────────────────────────────────────────
//  Metal Kernel: Write float4 buffer to RGBA8 texture
// ─────────────────────────────────────────────

kernel void writeResult(
    device   const float4            *src     [[buffer(0)]],
    texture2d<float, access::write>   dst     [[texture(0)]],
    constant uint                    &width   [[buffer(1)]],
    uint2                             gid     [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint index = gid.y * width + gid.x;
    float4 clamped = clamp(src[index], 0.0f, 1.0f);
    dst.write(clamped, gid);
}
