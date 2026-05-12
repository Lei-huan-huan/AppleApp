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

static inline float3 decode_nv12_rgb(float yv, float2 chroma) {
    float2 uv = chroma - float2(0.5, 0.5);
    float r = yv + 1.402 * uv.y;
    float g = yv - 0.344136 * uv.x - 0.714136 * uv.y;
    float b = yv + 1.772 * uv.x;
    return float3(r, g, b);
}

static inline float3 sample_nv12_rgb(texture2d<float> textureY,
                                     texture2d<float> textureUV,
                                     sampler samp,
                                     float2 coord) {
    float yv = textureY.sample(samp, coord).r;
    float2 c = textureUV.sample(samp, coord).rg;
    return decode_nv12_rgb(yv, c);
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> textureY [[texture(0)]],
                              texture2d<float> textureUV [[texture(1)]],
                              constant int &filterType [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 rgb = sample_nv12_rgb(textureY, textureUV, s, in.texCoord);
    const float3 W = float3(0.299, 0.587, 0.114);

    if (filterType == 1) rgb = float3(rgb.r, 0, 0);
    else if (filterType == 2) rgb = float3(0, rgb.g, 0);
    else if (filterType == 3) rgb = float3(0, 0, rgb.b);
    else if (filterType == 4) rgb = float3(dot(rgb, W));

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

// MARK: - 自定义相机（MagicCamera / GLES cartoon3，BGRA 纹理）

fragment float4 fragment_magic_crayon(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      constant float2 &singleStepOffset [[buffer(0)]],
                                      constant float &strength [[buffer(1)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float4 oralBGRA = tex.sample(s, in.texCoord);
    float3 oralRGB(oralBGRA.z, oralBGRA.y, oralBGRA.x);

    float3 maxValue(0.0);
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            float4 t = tex.sample(s, in.texCoord + singleStepOffset * float2(i, j));
            float3 trgb(t.z, t.y, t.x);
            maxValue.r = max(maxValue.r, trgb.r);
            maxValue.g = max(maxValue.g, trgb.g);
            maxValue.b = max(maxValue.b, trgb.b);
        }
    }
    float3 safeMax = max(maxValue, float3(1e-5));
    float3 textureColor = oralRGB / safeMax;

    const float3 W = float3(0.299, 0.587, 0.114);
    float gray = dot(textureColor, W);
    const float k = 0.223529;
    float alpha = min(gray, k) / k;
    textureColor = textureColor * alpha + (1.0 - alpha) * oralRGB;

    const float3x3 rgb2yiq = float3x3(
        float3(0.299, 0.596, 0.212),
        float3(0.587, -0.275, -0.523),
        float3(0.114, -0.321, 0.311));
    const float3x3 yiq2rgb = float3x3(
        float3(1.0, 1.0, 1.0),
        float3(0.956, -0.272, -1.106),
        float3(0.621, -1.703, 0.0));

    float3 yiqColor = textureColor * rgb2yiq;
    yiqColor.x = clamp(pow(gray, strength), 0.0, 1.0);
    float3 outRGB = yiqColor * yiq2rgb;

    return float4(outRGB.b, outRGB.g, outRGB.r, oralBGRA.a);
}

fragment float4 fragment_magic_sketch(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      constant float2 &singleStepOffset [[buffer(0)]],
                                      constant float &strength [[buffer(1)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float3 W = float3(0.299, 0.587, 0.114);

    float threshold = 0.0;
    float4 oralBGRA = tex.sample(s, in.texCoord);
    float3 oralRGB(oralBGRA.z, oralBGRA.y, oralBGRA.x);

    float3 maxValue(0.0);
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            float4 t = tex.sample(s, in.texCoord + singleStepOffset * float2(i, j));
            float3 trgb(t.z, t.y, t.x);
            maxValue = max(maxValue, trgb);
            threshold += dot(trgb, W);
        }
    }

    float gray1 = dot(oralRGB, W);
    float gray2 = max(dot(maxValue, W), 1e-5);
    float contour = gray1 / gray2;

    threshold = threshold / 25.0;
    float alpha = (gray1 > threshold) ? 1.0 : (gray1 / max(threshold, 1e-5));
    alpha = clamp(alpha, 0.0, 1.0);

    float result = contour * alpha + (1.0 - alpha) * gray1;
    result = pow(clamp(result, 0.0, 1.0), max(strength, 1e-5));
    return float4(result, result, result, oralBGRA.a);
}

fragment float4 fragment_cartoon3(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  constant float2 &singleStepOffset [[buffer(0)]],
                                  constant float &levels [[buffer(1)]],
                                  constant float &edgeThreshold [[buffer(2)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float3 W = float3(0.299, 0.587, 0.114);

    float4 centerBGRA = tex.sample(s, in.texCoord);
    float3 color(centerBGRA.z, centerBGRA.y, centerBGRA.x);
    float qLevels = max(levels, 1.0);
    float3 poster = floor(color * qLevels) / qLevels;

    float4 tlBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(-1.0, -1.0));
    float4 lBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(-1.0, 0.0));
    float4 blBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(-1.0, 1.0));
    float4 tBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(0.0, -1.0));
    float4 bBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(0.0, 1.0));
    float4 trBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(1.0, -1.0));
    float4 rBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(1.0, 0.0));
    float4 brBGRA = tex.sample(s, in.texCoord + singleStepOffset * float2(1.0, 1.0));

    float tl = dot(float3(tlBGRA.z, tlBGRA.y, tlBGRA.x), W);
    float l = dot(float3(lBGRA.z, lBGRA.y, lBGRA.x), W);
    float bl = dot(float3(blBGRA.z, blBGRA.y, blBGRA.x), W);
    float t = dot(float3(tBGRA.z, tBGRA.y, tBGRA.x), W);
    float b = dot(float3(bBGRA.z, bBGRA.y, bBGRA.x), W);
    float tr = dot(float3(trBGRA.z, trBGRA.y, trBGRA.x), W);
    float r = dot(float3(rBGRA.z, rBGRA.y, rBGRA.x), W);
    float br = dot(float3(brBGRA.z, brBGRA.y, brBGRA.x), W);

    float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br;
    float gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
    float edge = sqrt(gx * gx + gy * gy);

    float line = step(edgeThreshold, edge);
    float3 outRGB = mix(poster, float3(0.0), line);
    return float4(outRGB.b, outRGB.g, outRGB.r, centerBGRA.a);
}
