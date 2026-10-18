#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Independently translated recovered fragment0x3136dff plus the explicit
// Bradford/sRGB phone bridge and recovered Standard film table integration.
// Keep arithmetic synchronized with Core/RecoveredColor.cpp.
extern "C" {
namespace coreimage {
float4 recoveredKernel(sampler source, sampler chromaTable, sampler filmTable,
                       float4 grid, float4 options, destination dest) {
    float4 sampled = source.sample(source.transform(dest.coord()));
    float alpha = sampled.a;
    float3 rgb = alpha > 0.0f ? sampled.rgb / alpha : float3(0.0f);
    rgb = clamp(rgb, 0.0f, 1.0f);
    float3 p = rgb * 65535.0f;
    float avg = (p.r + p.g + p.b) * 0.3333333f;
    // Explicit app black policy: native source has an undefined exact-zero path.
    if (avg == 0.0f) return float4(0.0f, 0.0f, 0.0f, alpha);
    float dmax = max(max(abs(p.r-avg), abs(p.g-avg)), abs(p.b-avg));
    float gray = clamp((dmax/avg-0.005f)/(0.07f-0.005f), 0.0f, 1.0f);
    float3 ycc = float3(
        dot(float3(0.22065768270191272f,0.6547762036689073f,0.12456597392549729f), p),
        dot(float3(-0.1178468681274096f,-0.3297894099981833f,0.44773627811162264f), p),
        dot(float3(0.3121446064237095f,-0.2499638530923849f,-0.062080753345294754f), p));
    float divisor = options.x;
    float L = 15500.0f/options.y;
    float k = -0.123f;
    float limit = ycc.x < L ? k/(L*L)*ycc.x*ycc.x + (-2.0f*k/L)*ycc.x + (1.0f+k) : 1.0f;
    gray = max(min(gray, limit), 0.0f);
    float Y = max(ycc.x, 1e-10f);
    float2 coord = clamp(ycc.yz*divisor/Y-grid.zw, float2(0.0f), grid.xy-float2(1.0f));
    // The recovered boundary quirk is deliberate: fraction precedes index cap.
    float2 base = floor(coord);
    float2 fraction = coord-base;
    float2 cell = min(base, grid.xy-float2(2.0f));
    float2 a = chromaTable.sample(chromaTable.transform(cell+float2(0.5f,0.5f))).rg;
    float2 b = chromaTable.sample(chromaTable.transform(cell+float2(1.5f,0.5f))).rg;
    float2 c = chromaTable.sample(chromaTable.transform(cell+float2(0.5f,1.5f))).rg;
    float2 d = chromaTable.sample(chromaTable.transform(cell+float2(1.5f,1.5f))).rg;
    float2 chroma = ((a*(1.0f-fraction.x)+b*fraction.x)*(1.0f-fraction.y)
                  +(c*(1.0f-fraction.x)+d*fraction.x)*fraction.y)*Y*gray;
    float3 native = float3(
        Y+chroma.x*(-0.00012188356583590878f/divisor)+chroma.y*(1.4022426952670104f/divisor),
        Y+chroma.x*(-0.34562707769717743f/divisor)+chroma.y*(-0.7144779490935292f/divisor),
        Y+chroma.x*(1.7710155002182766f/divisor)+chroma.y*(-0.0001535080964643524f/divisor))/65535.0f;
    // Native film stage uses floor into 65536 entries, not interpolation.
    float3 indices = floor(min(max(native,0.0f)*65536.0f,65535.0f));
    float2 rpos = float2(indices.r-floor(indices.r/256.0f)*256.0f, floor(indices.r/256.0f))+0.5f;
    float2 gpos = float2(indices.g-floor(indices.g/256.0f)*256.0f, floor(indices.g/256.0f))+0.5f;
    float2 bpos = float2(indices.b-floor(indices.b/256.0f)*256.0f, floor(indices.b/256.0f))+0.5f;
    float3 encoded = float3(filmTable.sample(filmTable.transform(rpos)).r,
                            filmTable.sample(filmTable.transform(gpos)).r,
                            filmTable.sample(filmTable.transform(bpos)).r);
    native = pow(max(encoded,0.0f), float3(2.19921875f));
    float3 mapped = float3(
        dot(float3(1.5487231627750677f,-0.4931464183849373f,-0.055576604686429f),native),
        dot(float3(-0.06253000270524556f,1.0766231784366227f,-0.01409303602767471f),native),
        dot(float3(-0.015208859998233059f,-0.07651119599334996f,1.0917201956952851f),native));
    float3 blended = clamp(rgb+(mapped-rgb)*clamp(options.z,0.0f,1.0f),0.0f,1.0f);
    return float4(blended*alpha,alpha);
}
}
}
