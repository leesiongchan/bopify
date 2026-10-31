#include <metal_stdlib>
using namespace metal;

static float materialHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Fade detail before its period falls below two screen pixels.
static float materialGrooves(float r) {
    float fine = pow(0.5 + 0.5 * sin(r * 1050.0), 7.0);
    float finer = pow(0.5 + 0.5 * sin(r * 1670.0), 12.0);
    return 0.7 * mix(0.21, fine, 1.0 - smoothstep(1.5, 3.14, fwidth(r) * 1050.0))
         + 0.3 * mix(0.16, finer, 1.0 - smoothstep(1.5, 3.14, fwidth(r) * 1670.0));
}

static float materialGaps(float r) {
    float d = min(min(abs(r - 0.53), abs(r - 0.645)), min(abs(r - 0.76), abs(r - 0.865)));
    return 1.0 - smoothstep(0.002, 0.004 + fwidth(r), d);
}

[[stitchable]] half4 recordGlass(float2 position, half4 color, float2 size, float seed, float density, float opaque) {
    float radius = size.x * 0.5;
    float2 p = (position - size * 0.5) / radius;
    float r = length(p), a = atan2(p.y, p.x);
    float phase = sin(seed * 0.13) * 0.09;
    float x = p.x * cos(phase) - p.y * sin(phase);
    float y = p.x * sin(phase) + p.y * cos(phase);
    float field = sin(5.0*x + 1.3*sin(4.0*y)) + 0.42*sin(9.0*y - 3.0*x) + 0.21*sin(14.0*x + 8.0*y);
    float smoke = pow(0.5 + 0.5*sin(2.0*field + 0.4*a), 4.0);
    float wisps = pow(0.5 + 0.5*sin(13.0*field + 4.0*r), 18.0);
    float edge = smoothstep(0.965, 0.995, r);
    float alpha = min(0.8, density*(0.65 + 0.9*smoke) + 0.075*materialGrooves(r)
                      + 0.3*edge + 0.025*wisps + 0.06*materialGaps(r));
    float grain = (materialHash(position) - 0.5) * 0.025;
    float3 rgb = float3(99.0, 111.0, 105.0) / 255.0 + grain;
    if (opaque > 0.5) {
        alpha = 1.0;
        rgb = float3(0.16, 0.19, 0.18) + 0.08*smoke + grain;
    }
    alpha *= saturate((1.0 - r) * radius);
    return half4(half3(saturate(rgb) * alpha), half(alpha));
}

[[stitchable]] half4 recordNacre(float2 position, half4 color, float2 size, float seed) {
    float radius = size.x * 0.5;
    float2 p = (position - size * 0.5) / radius;
    float r = length(p), a = atan2(p.y, p.x) + sin(seed * 0.13) * 0.09;
    float w = r + 0.055*sin(3.0*a + 9.0*r) + 0.026*sin(7.0*a - 12.0*r) + 0.022*sin(9.0*p.x + 4.0*p.y);
    float layer = pow(0.5 + 0.5*sin(51.0*w + 0.5*sin(93.0*w)), 3.0);
    float seam = pow(0.5 + 0.5*sin(104.0*w), 17.0);
    seam = mix(0.13, seam, 1.0 - smoothstep(1.5, 3.14, fwidth(w)*104.0));
    float grain = (materialHash(position) - 0.5) * 3.0;
    float base = 177.0 + 31.0*layer - 12.0*seam - 11.0*materialGrooves(r)
               - 12.0*materialGaps(r) + grain - 24.0*smoothstep(0.965, 0.995, r);
    float overtone = sin(28.0*w + 0.2*a), warm = cos(3.0*p.x - 2.0*p.y);
    float3 rgb = (base + float3(9.0 + 5.0*warm + 4.0*overtone, 12.0 + 6.0*overtone,
                                4.0 - 4.0*warm + 8.0*overtone)) / 255.0;
    float alpha = saturate((1.0 - r) * radius);
    return half4(half3(saturate(rgb) * alpha), half(alpha));
}
