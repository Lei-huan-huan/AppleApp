#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_passthrough_A(uint vid [[vertex_id]]) {
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
    out.position = float4(pos[vid], 0, 1);
    out.texCoord = uv[vid];
    return out;
}

fragment float4 fragment_main_A(VertexOut in [[stage_in]],
                                texture2d<float> texY0 [[texture(0)]],
                                texture2d<float> texUV0 [[texture(1)]],
                                texture2d<float> texY1 [[texture(2)]],
                                texture2d<float> texUV1 [[texture(3)]],
                                texture2d<float> texY2 [[texture(4)]],
                                texture2d<float> texUV2 [[texture(5)]],
                                texture2d<float> texY3 [[texture(6)]],
                                texture2d<float> texUV3 [[texture(7)]],
                                constant float4 &videoAspects [[buffer(0)]],
                                constant float &cellAspect [[buffer(1)]],
                                constant float4 &letterboxColor [[buffer(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.texCoord;

    int index = 0;
    if (uv.x >= 0.5 && uv.y < 0.5) index = 1;
    else if (uv.x < 0.5 && uv.y >= 0.5) index = 2;
    else if (uv.x >= 0.5 && uv.y >= 0.5) index = 3;

    float2 localUV;
    localUV.x = (uv.x < 0.5) ? uv.x * 2.0 : (uv.x - 0.5) * 2.0;
    localUV.y = (uv.y < 0.5) ? uv.y * 2.0 : (uv.y - 0.5) * 2.0;

    float videoAspect = videoAspects[index];
    float2 sampleUV = localUV;

    if (videoAspect > cellAspect) {
        float activeHeight = cellAspect / videoAspect;
        float yMin = 0.5 - activeHeight * 0.5;
        float yMax = 0.5 + activeHeight * 0.5;
        if (localUV.y < yMin || localUV.y > yMax) {
            return letterboxColor;
        }
        sampleUV.y = (localUV.y - yMin) / activeHeight;
    } else {
        float activeWidth = videoAspect / cellAspect;
        float xMin = 0.5 - activeWidth * 0.5;
        float xMax = 0.5 + activeWidth * 0.5;
        if (localUV.x < xMin || localUV.x > xMax) {
            return letterboxColor;
        }
        sampleUV.x = (localUV.x - xMin) / activeWidth;
    }

    float y;
    float2 uvVal;
    if (index == 0) {
        y = texY0.sample(s, sampleUV).r;
        uvVal = texUV0.sample(s, sampleUV).rg - float2(0.5, 0.5);
    } else if (index == 1) {
        y = texY1.sample(s, sampleUV).r;
        uvVal = texUV1.sample(s, sampleUV).rg - float2(0.5, 0.5);
    } else if (index == 2) {
        y = texY2.sample(s, sampleUV).r;
        uvVal = texUV2.sample(s, sampleUV).rg - float2(0.5, 0.5);
    } else {
        y = texY3.sample(s, sampleUV).r;
        uvVal = texUV3.sample(s, sampleUV).rg - float2(0.5, 0.5);
    }

    float r = y + 1.402 * uvVal.y;
    float g = y - 0.344136 * uvVal.x - 0.714136 * uvVal.y;
    float b = y + 1.772 * uvVal.x;
    return float4(float3(r, g, b), 1.0);
}

static float4 sampleYUVSix(texture2d<float> texY, texture2d<float> texUV, float2 sampleUV, sampler s) {
    float yChan = texY.sample(s, sampleUV).r;
    float2 uvVal = texUV.sample(s, sampleUV).rg - float2(0.5, 0.5);
    float r = yChan + 1.402 * uvVal.y;
    float g = yChan - 0.344136 * uvVal.x - 0.714136 * uvVal.y;
    float b = yChan + 1.772 * uvVal.x;
    return float4(r, g, b, 1.0);
}

fragment float4 fragment_main_six(VertexOut in [[stage_in]],
                                  texture2d<float> texY0 [[texture(0)]],
                                  texture2d<float> texUV0 [[texture(1)]],
                                  texture2d<float> texY1 [[texture(2)]],
                                  texture2d<float> texUV1 [[texture(3)]],
                                  texture2d<float> texY2 [[texture(4)]],
                                  texture2d<float> texUV2 [[texture(5)]],
                                  texture2d<float> texY3 [[texture(6)]],
                                  texture2d<float> texUV3 [[texture(7)]],
                                  texture2d<float> texY4 [[texture(8)]],
                                  texture2d<float> texUV4 [[texture(9)]],
                                  texture2d<float> texY5 [[texture(10)]],
                                  texture2d<float> texUV5 [[texture(11)]],
                                  constant float *videoAspects [[buffer(0)]],
                                  constant float &cellAspect [[buffer(1)]],
                                  constant float4 &letterboxColor [[buffer(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.texCoord;

    int col = uv.x < 0.5 ? 0 : 1;
    int row;
    if (uv.y < 1.0 / 3.0) row = 0;
    else if (uv.y < 2.0 / 3.0) row = 1;
    else row = 2;
    int index = row * 2 + col;

    float2 localUV;
    localUV.x = (uv.x < 0.5) ? uv.x * 2.0 : (uv.x - 0.5) * 2.0;
    if (row == 0) localUV.y = uv.y * 3.0;
    else if (row == 1) localUV.y = (uv.y - 1.0 / 3.0) * 3.0;
    else localUV.y = (uv.y - 2.0 / 3.0) * 3.0;

    float videoAspect = videoAspects[index];
    float2 sampleUV = localUV;

    if (videoAspect > cellAspect) {
        float activeHeight = cellAspect / videoAspect;
        float yMin = 0.5 - activeHeight * 0.5;
        float yMax = 0.5 + activeHeight * 0.5;
        if (localUV.y < yMin || localUV.y > yMax) return letterboxColor;
        sampleUV.y = (localUV.y - yMin) / activeHeight;
    } else {
        float activeWidth = videoAspect / cellAspect;
        float xMin = 0.5 - activeWidth * 0.5;
        float xMax = 0.5 + activeWidth * 0.5;
        if (localUV.x < xMin || localUV.x > xMax) return letterboxColor;
        sampleUV.x = (localUV.x - xMin) / activeWidth;
    }

    switch (index) {
        case 0: return sampleYUVSix(texY0, texUV0, sampleUV, s);
        case 1: return sampleYUVSix(texY1, texUV1, sampleUV, s);
        case 2: return sampleYUVSix(texY2, texUV2, sampleUV, s);
        case 3: return sampleYUVSix(texY3, texUV3, sampleUV, s);
        case 4: return sampleYUVSix(texY4, texUV4, sampleUV, s);
        default: return sampleYUVSix(texY5, texUV5, sampleUV, s);
    }
}
