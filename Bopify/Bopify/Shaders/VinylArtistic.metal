#include <metal_stdlib>
using namespace metal;

static float2 artRotate(float2 p, float a) {
    return float2(cos(a) * p.x - sin(a) * p.y, sin(a) * p.x + cos(a) * p.y);
}

static float artLine(float distance, float width) {
    return 1 - smoothstep(max(0.0, width - 0.5), width + 0.5, distance);
}

static float petal(float a, float b, float amplitude, float phase) {
    return b + amplitude * cos(7 * a + phase) + 7 * sin(3 * a + 0.8);
}

[[stitchable]] half4 vinylBloom(float2 position, half4 color, float2 size, float seed,
                               half4 c0, half4 c1, half4 c2, half4 paper) {
    float2 q = artRotate((position / size - 0.5) * 720, fract(seed * 0.0137) * 0.25);
    float a = atan2(q.y, q.x), r = length(q);
    float pixel = max(length(float2(dfdx(q.x), dfdy(q.x))), 0.01);
    half3 dark = half3(0.094, 0.141, 0.169), rgb = c0.rgb;
    const float bases[6] = {346, 319, 285, 250, 220, 192};
    const float amplitudes[6] = {13, 25, 35, 36, 31, 23};
    const float phases[6] = {0.3, 0.45, 0.8, 1.1, 1.6, 1.9};
    half3 inks[6] = {c1.rgb, c2.rgb, c0.rgb, c1.rgb, paper.rgb, c0.rgb};
    for (int i = 0; i < 6; ++i) {
        float d = r - petal(a, bases[i], amplitudes[i], phases[i]);
        float aa = max(fwidth(d), 0.01);
        rgb = mix(rgb, inks[i], half(1 - smoothstep(-aa, aa, d)));
        rgb = mix(rgb, dark, half(1 - smoothstep(1.5, 1.5 + aa, abs(d))));
    }
    for (int i = 0; i < 18; ++i) {
        float d = r - petal(a, 260, 69, i * 6.2831853 / 18);
        float gradient = max(length(float2(dfdx(d), dfdy(d))), 0.01);
        half3 ink = i % 3 == 0 ? paper.rgb : i % 3 == 1 ? c1.rgb : c2.rgb;
        rgb = mix(rgb, ink, half(0.6 * artLine(abs(d) / gradient, 0.9 / pixel)));
    }
    float index = floor(a / 6.2831853 * 35 + 0.5);
    float theta = index / 35 * 6.2831853;
    float dotRadius = 324 + 9 * sin(7 * theta);
    float d = length(q - dotRadius * float2(cos(theta), sin(theta)));
    float radius = int(index) % 5 == 0 ? 4 : 2;
    rgb = mix(rgb, int(index) % 2 == 0 ? dark : paper.rgb, half(1 - smoothstep(radius, radius + pixel, d)));
    return half4(rgb, 1);
}

[[stitchable]] half4 vinylRhapsody(float2 position, half4 color, float2 size, float seed,
                                  half4 c0, half4 c1, half4 c2, half4 paper) {
    float2 p = artRotate((position / size - 0.5) * 2, fract(seed * 0.0137) * 0.25);
    float u = p.x + 0.12 * sin(p.y * 4.3), v = p.y + 0.09 * sin(p.x * 5.1);
    float f = cos(3 * M_PI_F * u) * cos(4 * M_PI_F * v) - cos(4 * M_PI_F * u) * cos(3 * M_PI_F * v);
    float t = (0.5 + 0.5 * sin(2.2 * f + 0.6 * u - 0.3 * v)) * 2.999;
    int i = int(floor(t));
    half3 inks[3] = {c0.rgb, c1.rgb, c2.rgb};
    half3 rgb = mix(inks[i], inks[(i + 1) % 3], half(fract(t)));
    float aa = max(fwidth(f), 0.001);
    rgb = mix(rgb, half3(0.086, 0.125, 0.169), half(1 - smoothstep(0.045, 0.045 + aa, abs(f))));
    // Local deterministic grains keep work constant per fragment instead of scanning particles.
    float2 cell = floor((p + 1) * 180);
    float grain = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
    float speck = smoothstep(0.82, 0.94, grain) * (1 - smoothstep(0.08, 0.13 + aa, abs(f)));
    rgb = mix(rgb, paper.rgb, half(speck));
    return half4(rgb, 1);
}

[[stitchable]] half4 vinylCarnival(float2 position, half4 color, float2 size, float seed,
                                  half4 c0, half4 c1, half4 c2, half4 paper) {
    float2 original = (position / size - 0.5) * 720;
    float2 q = artRotate(original, M_PI_F / 7 + fract(seed * 0.0137) * 0.25) + 360;
    float pixel = max(length(float2(dfdx(q.x), dfdy(q.x))), 0.01);
    half3 dark = half3(0.094, 0.141, 0.169), rgb = c0.rgb;
    const float2 centers[4] = {float2(100,115), float2(592,147), float2(128,595), float2(585,588)};
    const float radii[4] = {270, 218, 230, 269};
    half3 colors[3] = {c0.rgb, c1.rgb, c2.rgb};
    for (int g = 0; g < 4; ++g) {
        float2 d = q - centers[g];
        float r = length(d), radius = radii[g];
        float band = clamp((radius - r) / (radius / 6), 0.0, 5.999);
        int ring = int(floor(band));
        half3 inks[6] = {colors[(g + 1) % 3], colors[g % 3], paper.rgb, colors[(g + 2) % 3], dark, colors[g % 3]};
        half3 left = inks[ring], right = inks[(ring + 2) % 6];
        float aa = max(fwidth(band), 0.001);
        if (ring > 0) {
            float edge = smoothstep(0.0, aa, fract(band));
            left = mix(inks[ring - 1], left, half(edge));
            right = mix(inks[(ring + 1) % 6], right, half(edge));
        }
        half3 fill = mix(left, right, half(smoothstep(-pixel, pixel, d.x)));
        float mask = 1 - smoothstep(radius - pixel, radius + pixel, r);
        rgb = mix(rgb, fill, half(mask));
        float a = atan2(d.y, d.x);
        float nearest = floor((a - 0.2) / 6.2831853 * 21 + 0.5) / 21 * 6.2831853 + 0.2;
        float hatch = artLine(abs(r - radius * 0.78) / pixel, 8 / pixel)
            * artLine(abs(sin(a - nearest) * r) / pixel, 1.75 / pixel) * mask;
        rgb = mix(rgb, g % 2 == 0 ? paper.rgb : dark, half(hatch));
    }
    for (int i = 0; i < 13; ++i) {
        float2 center = float2(156 + i * 29, 98 + i * 40);
        if (length(center - 360) < 161.5) continue;
        float2 d = abs(artRotate(original + 360 - center, -0.6)) - float2(5,7);
        float mask = 1 - smoothstep(0.0, pixel, max(d.x, d.y));
        rgb = mix(rgb, i % 2 == 0 ? dark : paper.rgb, half(mask));
    }
    return half4(rgb, 1);
}
