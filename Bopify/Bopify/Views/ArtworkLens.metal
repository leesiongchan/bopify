#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] float2 artworkLens(float2 position, float diameter, float strength, float progress) {
    float2 unit = (position - diameter * 0.5) / (diameter * 0.5);
    float falloff = max(0.0, 1.0 - dot(unit, unit));
    // The lens relaxes at the perimeter and both endpoints, leaving settled artwork unaltered.
    float2 lens = unit * (0.14 * strength * falloff);
    lens.x += 0.10 * strength * falloff * sin(unit.y * M_PI_F + progress * M_PI_F);
    return position + lens * (diameter * 0.5);
}
