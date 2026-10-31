#include <metal_stdlib>
using namespace metal;

static float contourField(float2 p) {
    float u = p.x + 0.34 * sin(p.y * 3.3 + sin(p.x * 1.8)) + 0.13 * sin(p.y * 6.1 + p.x * 2);
    float v = p.y + 0.30 * sin(p.x * 3.2 - p.y * 0.6) + 0.13 * cos(p.x * 5.4 + p.y * 3.1);
    return 0.60 * sin(u * 3.9 + v * 1.4) + 0.49 * cos(v * 3.4 - u * 0.9) + 0.18 * sin(u * 7 + v * 4.2);
}

static float contourLine(float distance, float halfWidth) {
    return 1 - smoothstep(max(0.0, halfWidth - 0.5), halfWidth + 0.5, distance);
}

[[stitchable]] half4 vinylContours(float2 position, half4 color, float2 size, float seed,
                                   half4 c0, half4 c1, half4 c2, float style) {
    float2 q = (position / size - 0.5) * 720;
    // A song changes only a small phase/orientation, never the design's identity.
    float angle = fract(seed * 0.0137) * 0.25;
    q = float2(cos(angle) * q.x - sin(angle) * q.y, sin(angle) * q.x + cos(angle) * q.y);
    float pixel = max(length(float2(dfdx(q.x), dfdy(q.x))), 0.01);
    half3 dark = half3(0.047, 0.071, 0.082);
    half3 rgb = dark;
    if (style > 0.5 && style < 1.5) {
        float a = atan2(q.y, q.x), radius = length(q);
        float radialPixel = max(length(float2(dfdx(radius), dfdy(radius))), pixel);
        for (int i = 0; i < 9; ++i) {
            float b = 146 + i * 35;
            float target = b + 28 * sin(3 * a + b * 0.008) + 20 * sin(5 * a - b * 0.006) + 10 * sin(9 * a + b * 0.004);
            float d = abs(radius - target) / radialPixel;
            rgb = mix(rgb, c1.rgb, half(contourLine(d, 9 / radialPixel)));
            rgb = mix(rgb, c2.rgb, half(contourLine(d, 5 / radialPixel)));
            rgb = mix(rgb, dark, half(contourLine(d, 2 / radialPixel)));
            float accent = b + 17 + 28 * sin(3 * a + (b + 17) * 0.008)
                + 20 * sin(5 * a - (b + 17) * 0.006) + 10 * sin(9 * a + (b + 17) * 0.004);
            rgb = mix(rgb, c0.rgb, half(contourLine(abs(radius - accent) / radialPixel, 1.3 / radialPixel)));
        }
    } else {
        float f = contourField(q / 720 * 2.8);
        float gradient = max(length(float2(dfdx(f), dfdy(f))), 0.00001);
        if (style > 1.5) {
            float band = (f + 1.35) * 3.3;
            int index = (int(floor(band)) % 8 + 8) % 8;
            rgb = index < 2 || index == 6 ? c0.rgb : index < 4 || index == 5 ? c1.rgb : index == 4 ? c2.rgb : dark;
            float d = min(fract(band), 1 - fract(band)) / (gradient * 3.3);
            rgb = mix(rgb, dark, half(contourLine(d, 5.5 / pixel)));
            rgb = mix(rgb, c2.rgb, half(contourLine(d, 2 / pixel)));
        } else {
            for (int i = 0; i < 34; ++i) {
                float d = abs(f - (-1.25 + i * 0.076)) / gradient;
                float width = i % 7 == 0 ? 9 : i % 4 == 0 ? 3.6 : 2.1;
                half3 ink = i % 7 == 0 ? c2.rgb : i % 3 == 0 ? c0.rgb : i % 3 == 1 ? c1.rgb : c2.rgb;
                rgb = mix(rgb, ink, half(contourLine(d, width * 0.5 / pixel)));
            }
        }
    }
    return half4(rgb, 1);
}
