Shader "Elysia/SSR"
{
    Properties
    {
        _MainTex            ("Main Tex",    2D)                           = "white" {}
    }
    
    SubShader
    {
        Cull Off
        ZWrite Off
        ZTest Always

        HLSLINCLUDE
        #pragma target 4.5
        #pragma enable_d3d11_debug_symbols
        ENDHLSL
        
        Pass
        {
            Name "Elysia Linear SSR"
            
            HLSLPROGRAM
            #include_with_pragmas "SSR.hlsl"
            #pragma shader_feature SSR_BINARY_SEARCH
            #pragma shader_feature SSR_POTENTIAL_HIT
            #pragma vertex SSRVS
            #pragma fragment SSRScreenSpacePS

            PSInput SSRVS(VSInput i)
            {
                PSInput o = (PSInput)0;

                VertexPositionInputs vertexPosData = GetVertexPositionInputs(i.positionOS);
                o.positionCS = vertexPosData.positionCS;

                o.uv = i.uv;
                #if defined(UNITY_UV_STARTS_AT_TOP)
                    o.uv.y = 1 - i.uv.y;
                #endif

                return o;
            }

            PSOutput SSRViewSpacePS(PSInput i)
            {
                PSOutput o;
                
                float2 uv = (i.positionCS.xy - 0.5f) * _ViewSize.zw;
                float rawDepth = GetDeviceDepth(uv);
                UNITY_BRANCH
                if(rawDepth == 0)
                {
                    o.color = 0.f;
                    return o;
                }
                
                float3 posWS = ReBuildPosWS(uv, rawDepth);
                float3 normalWS = GetNormalWS(uv);
                float3 viewDir = normalize(posWS - _WorldSpaceCameraPos);
                float3 reflectDirWS = GerReflectWS(viewDir, normalWS);

                float3 reflectColor = 0.f;
                UNITY_LOOP
                for(int i = 0; i < _StepCount; ++i)
                {
                    float3 reflectPosWS = posWS + reflectDirWS * _StepSize * i;
                    float4 reflectPosCS = mul(UNITY_MATRIX_VP, float4(reflectPosWS, 1.f));
                    reflectPosCS.xyz /= reflectPosCS.w;
                    float2 reflectUV = reflectPosCS.xy * 0.5f + 0.5f;
                    #if defined(UNITY_UV_STARTS_AT_TOP)
                    reflectUV.y = 1.f - reflectUV.y;
                    #endif

                    if(reflectUV.x < 0.f || reflectUV.y < 0.f || reflectUV.x > 1.f || reflectUV.y > 1.f) break;

                    float reflectDepth = reflectPosCS.w;
                    float viewDepth = GetDeviceDepth(reflectUV);
                    viewDepth = LinearEyeDepth(viewDepth, _ZBufferParams);
                    if(reflectDepth > viewDepth && abs(reflectDepth - viewDepth) < _Thickness)
                    {
                        reflectColor = GetSourceRT(reflectUV);
                        break;
                    }
                }
                
                o.color.xyz = reflectColor;
                return o;
            }

            PSOutput SSRScreenSpacePS(PSInput i)
            {
                PSOutput o = (PSOutput)0;

                #pragma region Init_Data
                float2 uv = (i.positionCS.xy - 0.5f) * _ViewSize.zw;
                o.color = GetSourceRT(uv);
                float rawDepth = GetDeviceDepth(uv);
                if(rawDepth == 0)
                {
                    o.color = 0.f;
                    return o;
                }
                
                float3 posWS = ReBuildPosWS(uv, rawDepth);
                float3 normalWS = GetNormalWS(uv);
                float3 viewDir = normalize(posWS - _WorldSpaceCameraPos);
                float3 reflectDirWS = GerReflectWS(viewDir, normalWS);
                float3 dither = _BlueNoiseTex.Sample(sampler_Clamp_Linear, uv).xyz;
                //reflectDirWS += (dither - 0.5f) * lerp(0.f, 0.5f, _Roughness);
                float3 reflectDirVS = TransformWorldToViewDir(reflectDirWS, true);
                float3 startPosVS = TransformWorldToView(posWS);
                // Clip to the near plane
                float rayLength   = startPosVS.z + reflectDirVS.z * _MaxDistance > -_ProjectionParams.y ?
                    (-_ProjectionParams.y - startPosVS.z) / reflectDirVS.z : _MaxDistance;
                float3 endPosVS   = startPosVS + reflectDirVS * rayLength;

                float4 startPosCS = TransformWViewToHClip(startPosVS);
                float4 endPosCS   = TransformWViewToHClip(endPosVS);
                float  startK     = rcp(startPosCS.w);
                float  endK       = rcp(endPosCS.w);
                float2 startUV    = startPosCS.xy * float2(1.f, -1.f) * startK * 0.5f + 0.5f;
                float2 endUV      = endPosCS.xy * float2(1.f, -1.f) * endK * 0.5f + 0.5f;

                // _StepCount = distance(endUV, startUV) < 0.3 ? 16 : _StepCount;
                // _StepCount = distance(endUV, startUV) < 0.5  && distance(endUV, startUV) >= 0.3 ? 24 : _StepCount;
                // _StepCount = distance(endUV, startUV) < 0.6  && distance(endUV, startUV) >= 0.5 ? 32 : _StepCount;
                // _StepCount = distance(endUV, startUV) < 0.7  && distance(endUV, startUV) >= 0.6 ? 40 : _StepCount;
                // _StepCount = distance(endUV, startUV) < 0.8  && distance(endUV, startUV) >= 0.7 ? 48  : _StepCount;
                // _StepCount = distance(endUV, startUV) < 0.9  && distance(endUV, startUV) >= 0.8 ? 56  : _StepCount;
                // _StepCount = distance(endUV, startUV) <= 1.0 && distance(endUV, startUV) >= 0.9 ? 64  : _StepCount;
                
                #pragma endregion

                float w0 = 0.f, w1 = 0.f;
                float4 reflectColor = 0.f;
                bool isHit = false;
                float2 ditherUV = fmod(startUV * _ViewSize.xy, 4);
                float jitter = Dither[ditherUV.x * 4 + ditherUV.y];
                float stepSize = rcp(float(_StepCount)) * _StepSize;

                #if defined(SSR_POTENTIAL_HIT)
                    bool isLastHit = false;             // 上一次步进是否打中物体
                    bool isPotentialHit = false;        // 是否存在前一次落点在物体前方，而下一次落点却在物体后方(潜在的交点)
                    float2 potentialw = 0.f;            // 潜在的交点情况下, w0和w1
                    float minPotentialThicknessDiff = INFINITY; // 潜在的交点情况下, 最小厚度差
                    
                    UNITY_LOOP
                    for(int i = 0; i < _StepCount; ++i)
                    {
                        w1 = w0;
                        w0 += stepSize;
                    
                        float  reflectK     = lerp(startK, endK, w0);
                        float2 reflectUV    = lerp(startUV, endUV, w0);
                        float4 reflectPosCS = lerp(startPosCS, endPosCS, w0);
                    
                        if(reflectUV.x < 0.f || reflectUV.y < 0.f || reflectUV.x > 1.f || reflectUV.y > 1.f) break;
                    
                        float sampleDepth   = GetDeviceDepth(reflectUV).r;
                        sampleDepth         = LinearEyeDepth(sampleDepth, _ZBufferParams);
                        float rayDepth      = LinearEyeDepth(reflectPosCS.z * reflectK, _ZBufferParams);
                        float depthDiff     = rayDepth - sampleDepth;
                        float thicknessDiff = GetThicknessDiff(depthDiff, sampleDepth);
                        
                        if(depthDiff > 0.f)
                        {
                            // 落点在物体内
                            if(thicknessDiff < _Thickness)
                            {
                                isHit = true;
                                break;
                            }
                            // 上一次并未与物体相交，且本次depthDiff > 0.f、thicknessDiff >= _Thickness
                            // 说明上次落点在物体前方，本次在物体后方
                            else if(isLastHit == false)
                            {
                                isPotentialHit = true;

                                // 该情况下，若深度差更小则更新深度差和w0, w1，这样得到的结果是最接近正确(表面)的交点
                                if(minPotentialThicknessDiff > thicknessDiff)
                                {
                                    minPotentialThicknessDiff = thicknessDiff;
                                    potentialw = float2(w0, w1);
                                }
                            }
                        }

                        // 落点在物体内或后，则后续不进行潜在的交点的判断
                        isLastHit = depthDiff > 0.f ? true : false;
                    }
                #else
                    UNITY_LOOP
                    for(int i = 0; i < _StepCount; ++i)
                    {
                        w1  = w0;
                        w0 += stepSize;

                        float  reflectK     = lerp(startK, endK, w0);
                        float2 reflectUV    = lerp(startUV, endUV, w0);
                        float4 reflectPosCS = lerp(startPosCS, endPosCS, w0);

                        if(reflectUV.x < 0.f || reflectUV.y < 0.f || reflectUV.x > 1.f || reflectUV.y > 1.f) break;

                        float sampleDepth = GetDeviceDepth(reflectUV).r;
                        sampleDepth       = LinearEyeDepth(sampleDepth, _ZBufferParams);
                        float rayDepth    = LinearEyeDepth(reflectPosCS.z * reflectK, _ZBufferParams);
                        float depthDiff   = rayDepth - sampleDepth;
                        float thicknessDiff = GetThicknessDiff(depthDiff, sampleDepth);
                        
                        if(depthDiff > 0.f && thicknessDiff < _Thickness)
                        {
                            isHit = true;
                            break;
                        }
                    }
                #endif

                #if defined(SSR_POTENTIAL_HIT)
                    // 若交点直接跨过物体 或 打在物体内部，开始二分搜索
                    if(isHit == true || isPotentialHit == true)
                    {
                        // 若交点直接跨过物体
                        if(isHit == false)
                        {
                            w0 = potentialw.x;
                            w1 = potentialw.y;
                        }
                    
                        bool realHit = false;   // 是否真的打中物体
                        float2 hitUV;
                        float minThicknessDiff = _Thickness;
                        
                        UNITY_LOOP
                        for(int i = 0; i < _BinaryCount; ++i)
                        {
                            float w = 0.5f * (w0 + w1);
                            float3 reflectPosCS = lerp(startPosCS, endPosCS, w);
                            float2 reflectUV    = lerp(startUV, endUV, w);
                            float  reflectK     = lerp(startK,  endK,  w);
                            if(reflectUV.x < 0.f || reflectUV.y < 0.f || reflectUV.x > 1.f || reflectUV.y > 1.f) break;
                    
                            float sampleDepth   = GetDeviceDepth(reflectUV);
                            sampleDepth         = LinearEyeDepth(sampleDepth, _ZBufferParams);
                            float rayDepth      = LinearEyeDepth(reflectPosCS.z * reflectK, _ZBufferParams);
                            float depthDiff     = rayDepth - sampleDepth;
                            float thicknessDiff = GetThicknessDiff(depthDiff, sampleDepth);
                            
                            if(depthDiff > 0.f)
                            {
                                w0 = w;
                                if(isHit == true)
                                {
                                    hitUV = reflectUV;
                                }
                            }
                            else
                            {
                                w1 = w;
                            }

                            // 若交点直接跨过物体, 且厚度差小于最小的厚度差
                            if(isHit == false && abs(thicknessDiff) < minThicknessDiff)
                            {
                                realHit = true;
                                minThicknessDiff = thicknessDiff;
                                hitUV = reflectUV;
                            }
                        }
                    
                        if(isHit == true || realHit == true)
                        {
                            reflectColor = GetSourceRT(hitUV);
                        }
                    }
                #elif defined(SSR_BINARY_SEARCH)
                    if(isHit == true)
                    {
                        float2 hitUV;
                        
                        UNITY_LOOP
                        for(int i = 0; i < _BinaryCount; ++i)
                        {
                            float w = 0.5f * (w0 + w1);
                            float3 reflectPosCS = lerp(startPosCS, endPosCS, w);
                            float2 reflectUV    = lerp(startUV, endUV, w);
                            float  reflectK     = lerp(startK,  endK,  w);
                            if(reflectUV.x < 0.f || reflectUV.y < 0.f || reflectUV.x > 1.f || reflectUV.y > 1.f) break;
                    
                            // 深度反转
                            float sampleDepth = GetDeviceDepth(reflectUV);
                            float rayDepth = reflectPosCS.z * reflectK;
                            if(rayDepth <= sampleDepth)
                            {
                                w0 = w;
                                hitUV = reflectUV;
                            }
                            else
                            {
                                w1 = w;
                            }
                        }
                    
                        reflectColor = GetSourceRT(hitUV);
                    }
                #else
                    if(isHit == true)
                    {
                        float2 hitUV = lerp(startUV, endUV, w0);
                        reflectColor = GetSourceRT(hitUV);
                    }
                #endif
                
                o.color = reflectColor * 0.3;
                return o;
            }
            ENDHLSL
        }

        Pass
        {
            Name "SSR Combine"
            HLSLPROGRAM
            #include_with_pragmas "SSR.hlsl"
            #pragma vertex VS
            #pragma fragment Combine

            PSInput VS(VSInput i)
            {
                PSInput o = (PSInput)0;

                VertexPositionInputs vertexPosData = GetVertexPositionInputs(i.positionOS);
                o.positionCS = vertexPosData.positionCS;

                o.uv = i.uv;
                #if defined(UNITY_UV_STARTS_AT_TOP)
                    o.uv.y = 1 - i.uv.y;
                #endif

                return o;
            }
            
            PSOutput Combine(PSInput i)
            {
                PSOutput o;

                float2 uv = (i.positionCS.xy - 0.5f) * _ViewSize.zw;
                float4 sourceTex = _CameraColorTexture.Sample(sampler_Clamp_Linear, uv);
                float4 blurTex = _EvenBuffer.Sample(sampler_Clamp_Linear, uv);
                
                o.color = sourceTex + blurTex;
                return o;
            }
            ENDHLSL
        }
    }
}
