#pragma once

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Random.hlsl"

#pragma region Variable
#define INFINITY 1e10

float4 _ViewSize;
int    _StepCount;
int    _BinaryCount;
int    _RandomNum;
float  _StepSize;
float  _MaxDistance;
float  _Thickness;
float  _Roughness;
static half Dither[16] =
{
    0.0, 0.5, 0.125, 0.625,
    0.75, 0.25, 0.875, 0.375,
    0.187, 0.687, 0.0625, 0.562,
    0.937, 0.437, 0.812, 0.312
};

TEXTURE2D(_MainTex);
TEXTURE2D(_CameraColorTexture);
TEXTURE2D(_CameraDepthTexture);
TEXTURE2D(_NormalVSRT);
TEXTURE2D(_ThicknessTex);
TEXTURE2D(_GBuffer1);
TEXTURE2D(_GBuffer3);
TEXTURE2D(_OddBuffer);
TEXTURE2D(_EvenBuffer);
TEXTURE2D(_BlueNoiseTex);

SamplerState Smp_ClampU_ClampV_Linear;
SamplerState Smp_ClampU_RepeatV_Linear;
SamplerState Smp_RepeatU_RepeatV_Linear;
SamplerState Smp_RepeatU_ClampV_Linear;
SamplerState sampler_Clamp_Linear;
SamplerState sampler_Repeat_Linear;
SamplerState sampler_Point_Clamp;
SamplerState sampler_Point_Repeat;

struct VSInput
{
    float4 positionOS : POSITION;
    float2 uv         : TEXCOORD0;
};

struct PSInput
{
    float4 positionCS : SV_POSITION;
    float2 uv         : TEXCOORD0;
};

struct PSOutput
{
    float4 color : SV_Target;
};

float2 _RandomNumber;
#pragma endregion

float2 RandN2(float2 pos, float2 random)
{
    return frac(sin(dot(pos.xy + random, float2(12.9898, 78.233))) * float2(43758.5453, 28001.8384));
}
float3 Hash33(float3 pos)
{
    pos = frac(pos * float3(0.1031f, 0.1030f, 0.0973f));
    pos += dot(pos, pos.yxz + 33.33f);
    
    return frac((pos.xxy + pos.yxx) * pos.zyx);
}
// UE4 Random.ush
// 3D random number generator inspired by PCGs (permuted congruential generator).
uint3 Rand3DPCG16(int3 p)
{
    uint3 v = uint3(p);
    v = v * 1664525u + 1013904223u;

    // That gives a simple mad per round.
    v.x += v.y*v.z;
    v.y += v.z*v.x;
    v.z += v.x*v.y;
    v.x += v.y*v.z;
    v.y += v.z*v.x;
    v.z += v.x*v.y;

    // only top 16 bits are well shuffled
    return v >> 16u;
}
float2 Hammersley16( uint Index, uint NumSamples, uint2 Random )
{
    float E1 = frac( (float)Index / NumSamples + float( Random.x ) * (1.0 / 65536.0) );
    float E2 = float( ( reversebits(Index) >> 16 ) ^ Random.y ) * (1.0 / 65536.0);
    return float2( E1, E2 );
}
// 圆盘采样
float2 UniformSampleDisk(float2 E)
{
    float Theta = 2 * PI * E.x;
    float Radius = sqrt(E.y);
    return Radius * float2(cos(Theta), sin(Theta));
}
// [ Heitz 2018, "Sampling the GGX Distribution of Visible Normals" ]
float4 ImportanceSampleVisibleGGX( float2 DiskE, float a2, float3 V )
{
    // TODO float2 alpha for anisotropic
    float a = sqrt(a2);

    // stretch
    float3 Vh = normalize( float3( a * V.xy, V.z ) );

    // Orthonormal basis
    // Tangent0 is orthogonal to N.
    #if 1 // Stable tangent basis based on V.
    float3 Tangent0 = (V.z < 0.9999) ? normalize( cross( float3(0, 0, 1), V ) ) : float3(1, 0, 0);
    float3 Tangent1 = normalize(cross( Vh, Tangent0 ));
    #else
    float3 Tangent0 = (Vh.z < 0.9999) ? normalize( cross( float3(0, 0, 1), Vh ) ) : float3(1, 0, 0);
    float3 Tangent1 = cross( Vh, Tangent0 );
    #endif

    float2 p = DiskE;
    float s = 0.5 + 0.5 * Vh.z;
    p.y = (1 - s) * sqrt( 1 - p.x * p.x ) + s * p.y;

    float3 H;
    H  = p.x * Tangent0;
    H += p.y * Tangent1;
    H += sqrt( saturate( 1 - dot( p, p ) ) ) * Vh;

    // unstretch
    H = normalize( float3( a * H.xy, max(0.0, H.z) ) );

    float NoV = V.z;
    float NoH = H.z;
    float VoH = dot(V, H);

    float d = (NoH * a2 - NoH) * NoH + 1;
    float D = a2 / (PI*d*d);

    float G_SmithV = 2 * NoV / (NoV + sqrt(NoV * (NoV - NoV * a2) + a2));

    float PDF = G_SmithV * VoH * D / NoV;

    return float4(H, PDF);
}


float4 GetSourceRT(float2 uv)
{
    return _CameraColorTexture.Sample(sampler_Clamp_Linear, uv);
}
float GetThicknessDiff(float depthDiff, float linearSampleDepth)
{
    return depthDiff / linearSampleDepth;
}
float GetDeviceDepth(float2 uv)
{
    return _CameraDepthTexture.SampleLevel(sampler_Point_Clamp, uv, 0).r;
}
float3 ReBuildPosWS(float2 uv, float rawDepth)
{
    float4 positionNDC = float4(uv * 2.f - 1.f, rawDepth, 1.f);
    #if defined (UNITY_UV_STARTS_AT_TOP)
    positionNDC.y = - positionNDC.y;
    #endif
    
    positionNDC    = mul(UNITY_MATRIX_I_VP, positionNDC);
    positionNDC    /= positionNDC.w;

    return positionNDC;
}
float3 GetNormalWS(float2 uv)
{
    return _NormalVSRT.Sample(sampler_Clamp_Linear, uv);
}
float3 GerReflectWS(float3 viewDir, float3 normalWS)
{
    float3 reflectDir = reflect(viewDir, normalWS);
    reflectDir = normalize(reflectDir);

    return reflectDir;
}

// 计算pixel到屏幕边缘的距离
float SDF(float2 pos)
{
    float2 distance = abs(pos) - float2(1, 1);
    return length(max(0.f, distance) - min(max(distance.x, distance.y), 0.f));
}

float4 TransformViewToScreen(float3 posVS)
{
    float4 posCS = mul(UNITY_MATRIX_P, float4(posVS, 1.f));
    posCS.xyz   /= posCS.w;
    posCS.xy     = posCS.xy * float2(1.f, -1.f) * 0.5f + 0.5f;

    return posCS;
}

void InitData(float2 uv, inout float3 posVS, inout float3 normalVS, inout float3 reflectDir)
{
    posVS = ReBuildPosWS(uv, GetDeviceDepth(uv));
    
    normalVS = _NormalVSRT.SampleLevel(sampler_Clamp_Linear, uv, 0);
    
    reflectDir = reflect(normalize(posVS), normalize(normalVS));
    reflectDir = normalize(reflectDir);
}
void GetUVAndDepth(float3 posVS, inout float2 uv, inout float depth, inout float eyeDepth)
{
    float4 posCS = mul(UNITY_MATRIX_P, float4(posVS, 1.f));
    depth  = posCS.w;
    posCS /= posCS.w;
    
    uv     = posCS.xy * 0.5f + 0.5f;
    uv.y = 1.f - uv.y;

    eyeDepth = GetDeviceDepth(uv);
    eyeDepth = LinearEyeDepth(eyeDepth, _ZBufferParams);
}