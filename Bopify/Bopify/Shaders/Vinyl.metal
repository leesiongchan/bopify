#include <metal_stdlib>
using namespace metal;

static float hash1(float n) { return fract(sin(n * 127.1) * 43758.5453); }

static float ringNoise(float x) {
    float i = floor(x), f = fract(x), u = f * f * (3.0 - 2.0 * f);
    return mix(hash1(i), hash1(i + 1.0), u);
}

/// Rotationally symmetric vinyl under a fixed light, so it never needs to turn: grooves catch the light in two
/// opposing wedges, track gaps and the run-out read as polished bands, and the rim is bevelled.
[[stitchable]] half4 vinylDisc(float2 position, half4 color, float2 size) {
    float radius = size.x * 0.5;
    float2 d = position - radius;
    float distance = length(d), r = distance / radius;
    if (r > 1.0) return half4(0);
    float facing = cos(atan2(d.y, d.x) + 2.25);   // light from the upper left
    float a = abs(facing);
    // Groove density varies ring to ring and song to song; `u` keeps the pattern independent of the drawn size.
    float u = r * 200.0;
    float rings = 0.55 * ringNoise(u * 0.9) + 0.25 * ringNoise(u * 0.17 + 40.0) + 0.2 * ringNoise(u * 3.1 + 9.0);
    float base = 0.028 + 0.018 * rings, highlight = 0;
    bool gap = abs(r - 0.53) < 0.006 || abs(r - 0.645) < 0.006 || abs(r - 0.76) < 0.006 || abs(r - 0.865) < 0.006;
    if (r < 0.345) {
        base = 0.02;
    } else if (r < 0.395) {
        highlight = pow(a, 5.0) * 0.22 + 0.03;
    } else if (gap) {
        base = 0.018;
        highlight = pow(a, 6.0) * 0.32;
    } else if (r < 0.95) {
        highlight = (pow(a, 60.0) * 0.85 + pow(a, 9.0) * 0.22) * (0.45 + 0.75 * rings);
        highlight *= 0.75 + 0.25 * sin(u * 2.9);
    } else if (r < 0.982) {
        highlight = pow(a, 7.0) * 0.2 + 0.02;
    } else {
        base = 0.012;
        highlight = max(0.0, facing) * 0.45;
    }
    float2 g = d / radius + float2(0.42, 0.48);
    float gloss = exp(-dot(g, g) / 0.09) * 0.07;
    float3 tint = facing > 0 ? float3(0.92, 0.97, 1.0) : float3(1.0, 0.95, 0.88);
    float3 rgb = pow(base + highlight * tint + gloss, 1.0 / 1.6);
    float alpha = clamp((radius - distance) * 2.4, 0.0, 1.0);
    return half4(half3(min(rgb, 1.0) * alpha), half(alpha));
}

/// Matte fibre for the paper label and the sleeve's plastic.
[[stitchable]] half4 paperGrain(float2 position, half4 color) {
    float2 cell = floor(position * 2.0);
    float grain = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
    return half4(color.rgb * half(1.0 - 0.1 * grain), color.a);
}
