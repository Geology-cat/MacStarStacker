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
