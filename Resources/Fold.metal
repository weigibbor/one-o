// One-O fold effect.
// Copyright (c) 2026 GE Labs, LLC. MIT licensed.
//
// The desktop is treated as a flat plane standing in the world. The panel swings about the hinge
// (the bottom edge of the screen) while the viewer's eye stays put, so every pixel shows whatever
// part of that fixed plane the eye sees through it. The result reads as the desktop passing through
// the moving panel rather than sliding with it. Blur and darkening grow with distance from the hinge,
// which is where the panel travels farthest and the illusion needs the most help.

#include <metal_stdlib>
using namespace metal;

struct FoldUniforms {
    float2 res;       // drawable size, pixels
    float  phi;       // panel rotation away from the open position, radians
    float  motion;    // 0...1 strength of blur and darkening
    float  eyeZ;      // eye distance from the panel, pixels
    float  maxRadius; // blur radius at the far edge, pixels
    float  maxLod;    // highest mip level available on the desktop texture
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut foldVertex(uint id [[vertex_id]]) {
    const float2 corners[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    VertexOut out;
    out.position = float4(corners[id], 0.0, 1.0);
    return out;
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             constant FoldUniforms &u [[buffer(0)]],
                             texture2d<float> desktop [[texture(0)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge, coord::normalized);
    const float2 p = in.position.xy;                       // pixels, origin top left
    const float d = u.res.y - p.y;                         // distance up from the hinge

    // Fixed front-view projection: follow the eye ray through this panel point onto the flat plane.
    const float k  = u.eyeZ / max(u.eyeZ - d * sin(u.phi), 1.0);
    const float dp = d * cos(u.phi) * k;
    const float2 src = float2(u.res.x * 0.5 + (p.x - u.res.x * 0.5) * k, u.res.y - dp);
    const float2 uv = src / u.res;
    if (any(uv < 0.0) || any(uv > 1.0)) { return float4(0.0, 0.0, 0.0, 1.0); }

    const float edge   = clamp(d / u.res.y, 0.0, 1.0);
    const float radius = u.maxRadius * u.motion * pow(edge, 1.35);
    const float dark   = u.motion * pow(clamp((edge - 0.2) / 0.8, 0.0, 1.0), 1.35);

    float3 colour;
    if (radius < 0.5) {
        colour = desktop.sample(smp, uv, level(0.0)).rgb;
    } else {
        // Plus-shaped taps on the mip chain: five samples buy a blur that reads as continuous.
        const float lod = clamp(log2(radius), 0.0, u.maxLod);
        const float2 step = radius / u.res;
        colour  = desktop.sample(smp, uv, level(lod)).rgb * 0.4;
        colour += desktop.sample(smp, clamp(uv + float2(step.x, 0.0), 0.0, 1.0), level(lod)).rgb * 0.15;
        colour += desktop.sample(smp, clamp(uv - float2(step.x, 0.0), 0.0, 1.0), level(lod)).rgb * 0.15;
        colour += desktop.sample(smp, clamp(uv + float2(0.0, step.y), 0.0, 1.0), level(lod)).rgb * 0.15;
        colour += desktop.sample(smp, clamp(uv - float2(0.0, step.y), 0.0, 1.0), level(lod)).rgb * 0.15;
    }
    return float4(colour * (1.0 - min(1.0, dark * 2.0)), 1.0);
}
