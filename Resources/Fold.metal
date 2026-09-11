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

// ---------------------------------------------------------------------------------------------
// "Hold the plane" effect. Design and shader math after jh3y/lid-plane (MIT, Copyright (c) 2026 Jhey),
// see NOTICE. The desktop keeps its angle in space while the physical panel tilts around it; blur
// grows with height and with the tilt, and the image boundary is feathered instead of cut.
// p = (delta radians, aspect, blur on, projection: 0 none / 1 parallel / 2 perspective)

struct HoldVertexOut { float4 position [[position]]; float2 uv; };

vertex HoldVertexOut holdVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2.0 - 1.0, 0.0, 1.0), float2(p.x, 1.0 - p.y) };
}

fragment float4 holdFragment(HoldVertexOut in [[stage_in]], texture2d<float> art [[texture(0)]],
                             texture2d<float> b1 [[texture(1)]], texture2d<float> b2 [[texture(2)]],
                             texture2d<float> b3 [[texture(3)]], texture2d<float> b4 [[texture(4)]],
                             constant float4 &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float height = 1.0 - uv.y;                       // 0 at the hinge, 1 at the top edge
    float a = clamp(p.x, -0.65, 1.25);
    float depth = height * sin(a);
    if (p.w > 0.5) {
        float3 eye = float3(0.0, 0.65, 1.6);
        float3 physical = float3((uv.x - 0.5) * p.y, height * cos(a), depth);
        float t = p.w > 1.5 ? eye.z / max(0.25, eye.z - physical.z) : 1.0;
        float3 hit = eye + t * (physical - eye);
        uv = float2(hit.x / p.y + 0.5, 1.0 - hit.y);
    }
    float radius = p.z * smoothstep(0.08, 1.0, height) * abs(sin(a)) * 65.0;
    float3 color;
    if (radius < 2.0)       color = mix(art.sample(s, uv).rgb, b1.sample(s, uv).rgb, radius / 2.0);
    else if (radius < 6.0)  color = mix(b1.sample(s, uv).rgb, b2.sample(s, uv).rgb, (radius - 2.0) / 4.0);
    else if (radius < 16.0) color = mix(b2.sample(s, uv).rgb, b3.sample(s, uv).rgb, (radius - 6.0) / 10.0);
    else                    color = mix(b3.sample(s, uv).rgb, b4.sample(s, uv).rgb, clamp((radius - 16.0) / 24.0, 0.0, 1.0));
    float2 sourceSize = float2(art.get_width(), art.get_height());
    float sigmaPixels = radius * sourceSize.y / 1000.0;
    float2 feather = max(3.0 * sigmaPixels / sourceSize, fwidth(uv));
    float2 coverage = smoothstep(-feather, feather, uv) * (1.0 - smoothstep(1.0 - feather, 1.0 + feather, uv));
    float mask = coverage.x * coverage.y;
    return float4(mix(float3(0.02, 0.035, 0.05), color, mask), 1.0);
}
