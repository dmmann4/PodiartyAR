#include <metal_stdlib>

using namespace metal;

struct Uniforms
{
    float minDepth;
    float maxDepth;
    float3x3 transform;
};

constant float minAlpha = 0.3;
constant float depthFeather = 0.002; // meters

kernel void DepthColoringFilter(texture2d<float, access::sample> colorTexture [[texture(0)]],
                                texture2d<float, access::sample> depthTexture [[texture(1)]],
                                texture2d<float, access::write> resultTexture [[texture(2)]],
                                constant Uniforms *uniforms [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]])
{
    constexpr sampler colorSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    
    float2 uv = (uniforms->transform * float3(float2(gid), 1.0)).xy;

    float4 color = colorTexture.sample(colorSampler, uv);
    float  depth = depthTexture.sample(depthSampler, uv).r;

    float alpha = max(smoothstep(uniforms->maxDepth + depthFeather, uniforms->maxDepth, depth),
                      smoothstep(uniforms->minDepth, uniforms->minDepth - depthFeather, depth));
    
    // Constrain the range of alpha adjustment
    color *= mix(minAlpha, 1.0, alpha);
    
    resultTexture.write(color, gid);
}

kernel void DrawColorTexture(texture2d<float, access::sample> colorTexture [[texture(0)]],
                             texture2d<float, access::write> resultTexture [[texture(1)]],
                             constant Uniforms *uniforms [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    constexpr sampler colorSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    
    float2 uv = (uniforms->transform * float3(float2(gid), 1.0)).xy;
    
    float4 color = colorTexture.sample(colorSampler, uv);
    color.rgb *= minAlpha;
    
    resultTexture.write(color, gid);
}

struct SmoothingParams
{
    int   radius;
    float sigmaSpace;
    float sigmaDepth;
};

kernel void SmoothDepthBilateral(texture2d<float, access::read> sourceTexture [[texture(0)]],
                                  texture2d<float, access::write> destTexture [[texture(1)]],
                                  constant SmoothingParams *params [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= sourceTexture.get_width() || gid.y >= sourceTexture.get_height()) {
        return;
    }

    float centerDepth = sourceTexture.read(gid).r;

    // Don't try to smooth invalid/zero depth
    if (centerDepth <= 0.0) {
        destTexture.write(float4(centerDepth), gid);
        return;
    }

    int radius = params->radius;
    float sigmaSpace = params->sigmaSpace;
    float sigmaDepth = params->sigmaDepth;

    float sumWeight = 0.0;
    float sumDepth = 0.0;

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 samplePos = int2(gid) + int2(dx, dy);

            if (samplePos.x < 0 || samplePos.y < 0 ||
                samplePos.x >= int(sourceTexture.get_width()) ||
                samplePos.y >= int(sourceTexture.get_height()))
            {
                continue;
            }

            float sampleDepth = sourceTexture.read(uint2(samplePos)).r;
            if (sampleDepth <= 0.0) continue;

            float spaceDist2 = float(dx * dx + dy * dy);
            float depthDiff = sampleDepth - centerDepth;
            float depthDist2 = depthDiff * depthDiff;

            float weight = exp(-spaceDist2 / (2.0 * sigmaSpace * sigmaSpace)) *
                           exp(-depthDist2 / (2.0 * sigmaDepth * sigmaDepth));

            sumWeight += weight;
            sumDepth += weight * sampleDepth;
        }
    }

    float result = (sumWeight > 0.0) ? (sumDepth / sumWeight) : centerDepth;
    destTexture.write(float4(result), gid);
}
