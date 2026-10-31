#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// The edge nearest the spindle leads; the trailing edge keeps its width until it is drawn into the neck.
static float rowProgress(float row, float progress, bool upward) {
    float trailing = upward ? row : 1.0 - row;
    return smoothstep(0.0, 1.0, clamp((progress - 0.42 * trailing) / 0.58, 0.0, 1.0));
}

static float rowY(float row, float progress, float4 source, float2 target, float zoom) {
    float centerY = source.y + source.w * 0.5;
    return centerY + (row - 0.5) * source.w * zoom
        + (target.y - centerY) * rowProgress(row, progress, target.y < centerY);
}

[[stitchable]] half4 spindlePull(float2 position, SwiftUI::Layer layer, float4 source,
                               float2 target, float progress, float rounding, float angle) {
    float zoom = 1.0 + 0.22 * sin(M_PI_F * min(1.0, progress / 0.32));
    float top = rowY(0.0, progress, source, target, zoom);
    float bottom = rowY(1.0, progress, source, target, zoom);
    if (position.y < top || position.y > bottom) return half4(0);

    // Rows stay ordered, so a bounded inverse lookup samples a continuous image without sliced-view seams.
    float lower = 0.0, upper = 1.0;
    for (int i = 0; i < 12; ++i) {
        float middle = (lower + upper) * 0.5;
        if (rowY(middle, progress, source, target, zoom) < position.y) lower = middle;
        else upper = middle;
    }
    float row = (lower + upper) * 0.5;
    float2 center = source.xy + source.zw * 0.5;
    bool upward = target.y < center.y;
    float travel = rowProgress(row, progress, upward);
    float leading = upward ? 1.0 - row : row;
    float width = source.z * zoom * (1.0 - 0.78 * leading * sin(M_PI_F * travel));
    float bow = sin(M_PI_F * row) * sin(M_PI_F * progress) * clamp(target.x - center.x, -24.0, 24.0);
    float centerX = mix(center.x, target.x, travel) + bow;
    float2 local = float2((position.x - centerX) / max(width, 0.01) * source.z, (row - 0.5) * source.w);

    float radius = mix(5.0, min(source.z, source.w) * 0.5, rounding);
    float2 edge = abs(local) - source.zw * 0.5 + radius;
    float distance = length(max(edge, 0.0)) + min(max(edge.x, edge.y), 0.0) - radius;
    if (distance > 1.0) return half4(0);
    float turn = angle;
    float2 sample = float2(cos(turn) * local.x + sin(turn) * local.y,
                          -sin(turn) * local.x + cos(turn) * local.y) + center;
    return layer.sample(sample) * half(1.0 - smoothstep(-0.5, 0.5, distance));
}
