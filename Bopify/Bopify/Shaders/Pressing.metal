#include <metal_stdlib>
using namespace metal;

static float lattice(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float noise(float2 p) {
    float2 cell = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(lattice(cell), lattice(cell + float2(1, 0)), u.x),
               mix(lattice(cell + float2(0, 1)), lattice(cell + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float value = 0, weight = 0.5;
    for (int octave = 0; octave < 4; ++octave) {
        value += weight * noise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        weight *= 0.5;
    }
    return value;
}

[[stitchable]] half4 pressing(float2 position, half4 color, float2 size, float seed,
                            half4 c0, half4 c1, half4 c2) {
    float2 p = position / size * 3.0 + float2(seed, seed * 0.37);
    float2 warp = float2(fbm(p), fbm(p + float2(4.7, 8.3)));
    float stripe = dot(p + warp * 2.2, float2(0.7, 1.1)) + fbm(p + warp) * 1.6;
    float ramp = (1.0 - abs(fract(stripe) * 2.0 - 1.0)) * 4.0;
    half3 dark = half3(0.02, 0.025, 0.025);
    half3 rgb;
    if (ramp < 1) rgb = mix(c0.rgb, c2.rgb, half(ramp));
    else if (ramp < 2) rgb = mix(c2.rgb, c1.rgb, half(ramp - 1));
    else if (ramp < 3) rgb = mix(c1.rgb, dark, half(ramp - 2));
    else rgb = mix(dark, c0.rgb, half(ramp - 3));
    return half4(rgb, 1);
}
