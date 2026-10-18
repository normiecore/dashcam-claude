#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Original analytic finish. Rec.709 luminance weights are standard constants.
// f(y)=y+0.08*y*(1-y)*(1-2*y) on [0,1]: endpoints are fixed and
// the derivative is >=0.96. Scaling all RGB channels together preserves
// linear-light chromaticity. Do not clamp wide-gamut source RGB channels.
extern "C" {
namespace coreimage {
float4 naturalFinish(sampler source, float strength, destination dest) {
    float4 sample = source.sample(source.transform(dest.coord()));
    if (sample.a <= 0.0f) return float4(0.0f);
    float3 rgb = sample.rgb / sample.a;
    float y = clamp(dot(rgb, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f, 1.0f);
    float ratio = 1.0f + 0.08f * (1.0f-y) * (1.0f-2.0f*y);
    float peak = max(max(rgb.r, rgb.g), rgb.b);
    if (ratio > 1.0f && peak > 0.0f) {
        ratio = min(ratio, peak <= 1.0f ? 1.0f/peak : 1.0f);
    }
    return float4(rgb * mix(1.0f, ratio, clamp(strength,0.0f,1.0f)) * sample.a, sample.a);
}
}
}
