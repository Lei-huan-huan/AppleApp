#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_passthrough(uint vid [[vertex_id]],
                                    constant float2 &scale [[buffer(1)]]) {
    float2 pos[4] = {
        float2(-1.0, -1.0),
        float2(1.0, -1.0),
        float2(-1.0, 1.0),
        float2(1.0, 1.0)
    };
    float2 uv[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(pos[vid] * scale, 0, 1);
    out.texCoord = uv[vid];
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> textureY [[texture(0)]],
                              texture2d<float> textureUV [[texture(1)]],
                              constant int &filterType [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float y = textureY.sample(s, in.texCoord).r;
    float2 uv = textureUV.sample(s, in.texCoord).rg - float2(0.5, 0.5);

    float r = y + 1.402 * uv.y;
    float g = y - 0.344136 * uv.x - 0.714136 * uv.y;
    float b = y + 1.772 * uv.x;
    float3 rgb = float3(r, g, b);

    if (filterType == 1) rgb = float3(rgb.r, 0, 0);
    if (filterType == 2) rgb = float3(0, rgb.g, 0);
    if (filterType == 3) rgb = float3(0, 0, rgb.b);
    if (filterType == 4) rgb = float3((r + g + b) / 3.0);
    return float4(rgb, 1.0);
}

// MARK: - 图生视频（与 IosTest1 SlideshowMetalExporter 一致）

struct ImageTransitionUniform {
    float progress;
    int effectType;
};

fragment float4 fragment_image_transition(VertexOut in [[stage_in]],
                                          texture2d<float> fromTex [[texture(0)]],
                                          texture2d<float> toTex [[texture(1)]],
                                          constant ImageTransitionUniform &uniforms [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float p = clamp(uniforms.progress, 0.0, 1.0);
    int effect = uniforms.effectType;

    if (effect == 0) {
        float4 c = (p < 1.0) ? fromTex.sample(s, in.texCoord) : toTex.sample(s, in.texCoord);
        return c;
    }

    if (effect == 1) {
        float4 a = fromTex.sample(s, in.texCoord);
        float4 b = toTex.sample(s, in.texCoord);
        return mix(a, b, p);
    }

    if (effect == 2) {
        float fromOffset = -p;
        float toOffset = 1.0 - p;
        float2 uvA = in.texCoord + float2(fromOffset, 0.0);
        float2 uvB = in.texCoord + float2(toOffset, 0.0);
        bool inA = uvA.x >= 0.0 && uvA.x <= 1.0;
        bool inB = uvB.x >= 0.0 && uvB.x <= 1.0;
        float4 ca = inA ? fromTex.sample(s, uvA) : float4(0.0, 0.0, 0.0, 1.0);
        float4 cb = inB ? toTex.sample(s, uvB) : float4(0.0, 0.0, 0.0, 1.0);
        return inB ? cb : ca;
    }

    float zoomA = 1.0 + p * 0.15;
    float zoomB = 1.12 - p * 0.12;
    float2 center = float2(0.5, 0.5);
    float2 uvA = (in.texCoord - center) / zoomA + center;
    float2 uvB = (in.texCoord - center) / zoomB + center;
    float4 a = fromTex.sample(s, clamp(uvA, float2(0.0), float2(1.0)));
    float4 b = toTex.sample(s, clamp(uvB, float2(0.0), float2(1.0)));
    return mix(a, b, p);
}
