using System.Collections.Generic;
using Unity.Mathematics;

namespace UnityEngine.Rendering.Universal
{
    public class SSRRF : ScriptableRendererFeature
    {
        #region Variable
        [System.Serializable]
        public class PassSetting
        {
            public string profilerTag = "SSR";
            public RenderPassEvent passEvent = RenderPassEvent.AfterRenderingTransparents;
            public Shader shader;
            public ComputeShader blurShader;
            public Texture2D bluseNoiseTex;

            [Range(0, 0.1f)] public float thickness     = 0.01f;
            [Range(0, 1000)] public float maxDistance   = 100f;
            [Range(1, 64)]   public int   stepCount     = 32;
            [Range(1, 16)]   public int   binaryCount   = 4;
            [Range(1, 10)]   public float stepSize      = 1;
            [Range(0, 1)]    public float roughness     = 0;
            [Range(0, 1)]    public float blurIntensity = 1;
            [Range(0, 255)]  public float blurMaxRadius = 32;
            
            public float GetRadius()
            {
                return blurIntensity * blurMaxRadius;
            }
            
            public LayerMask           m_layerMask;
            public RenderTextureFormat m_texFormat;
        }

        public PassSetting m_passSetting = new PassSetting();
        SSRRenderPass m_renderPass;
        #endregion
        
        public override void Create()
        {
            m_renderPass = new SSRRenderPass(m_passSetting);
        }
        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            var volume = VolumeManager.instance.stack.GetComponent<SSRVolume>();

            if (volume != null && volume.enable == true)
            {
                m_renderPass.Setup(volume, (UniversalRenderer)renderer);
                renderer.EnqueuePass(m_renderPass);
            }
        }
    }
    
    class SSRRenderPass : ScriptableRenderPass
    {
        #region  Variable
        private SSRRF.PassSetting _passSetting;
        private SSRVolume                    _volume;
        private Shader                       _shader;
        private ComputeShader                _computeShader;
        private Material                     _material;
        private UniversalRenderer            _Renderer;
        private FilteringSettings            _filteringSettings;
        private SortingCriteria              _sortingCriteria;
        private DrawingSettings              _drawingSettings;
        private List<ShaderTagId>            _ShaderTagIdList = new List<ShaderTagId>()
        {
            new ShaderTagId("SRPDefaultUnlit"),
            new ShaderTagId("UniversalForward"),
            new ShaderTagId("UniversalForwardOnly"),
            new ShaderTagId("LightweightForward")
        };
        private const string CommandBufferTag = "Screen Space Reflection Pass";
        
        private RenderTextureDescriptor _descriptor;
        private RenderTargetIdentifier  _cameraRT;
        private RenderTargetIdentifier  _cameraColorRT;
        private RenderTargetIdentifier  _cameraDepthRT;
        private RenderTargetIdentifier  _OddBuffer;
        private RenderTargetIdentifier  _EvenBuffer;
        private static int _OddBufferTexID   = Shader.PropertyToID("_OddBuffer");
        private static int _EvenBufferTexID  = Shader.PropertyToID("_EvenBuffer");
        private static int _cameraColorTexID = Shader.PropertyToID("_CameraColorTexture");
        private static int _cameraDepthTexID = Shader.PropertyToID("_CameraDepthTexture");
        
        private Vector4 _texSize;
        #endregion

        #region Setup
        public SSRRenderPass(SSRRF.PassSetting passSetting)
        {
            _passSetting = passSetting;
            this.renderPassEvent = _passSetting.passEvent;
            
            if (_passSetting.shader == null)
            {
                _shader = Shader.Find("Elysia/SSR");
            }
            else
            {
                _shader = _passSetting.shader;
                _material = CoreUtils.CreateEngineMaterial(_shader);
            }
            
            _computeShader = _passSetting.blurShader;
        }
        
        public void Setup(SSRVolume volume, UniversalRenderer renderer)
        {
            _volume   = volume;
            _Renderer = renderer;
        }
        
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            _descriptor                 = renderingData.cameraData.cameraTargetDescriptor;
            _descriptor.msaaSamples     = 1;
            _descriptor.depthBufferBits = 0;
            _descriptor.enableRandomWrite = true;
            _descriptor.colorFormat     = _passSetting.m_texFormat;
            _texSize                    = new Vector4(_descriptor.width, _descriptor.height, 1f / _descriptor.width, 1f / _descriptor.height);
            
            _cameraRT      = _Renderer.cameraColorTarget;
            _cameraColorRT = new RenderTargetIdentifier(_cameraColorTexID);
            cmd.GetTemporaryRT(_cameraColorTexID,  _descriptor, FilterMode.Point);
            _cameraDepthRT = _Renderer.cameraDepthTarget;
            cmd.GetTemporaryRT(_OddBufferTexID,  _descriptor, FilterMode.Point);
            cmd.GetTemporaryRT(_EvenBufferTexID, _descriptor, FilterMode.Point);
            _OddBuffer     = new RenderTargetIdentifier(_OddBufferTexID);
            _EvenBuffer    = new RenderTargetIdentifier(_EvenBufferTexID);
        }
        
        #endregion

        #region Execute
        private Vector4 GetTextureSizeParams(Vector2Int size)
        {
            return new Vector4(size.x, size.y, 1.0f / size.x, 1.0f / size.y);
        }
        
        void DoSSR(CommandBuffer cmd, ref RenderingData renderingData, ScriptableRenderContext context, RenderTargetIdentifier targetRT, Material material)
        {
            if (material == null) return;
            
            material.SetVector("_ViewSize",     _texSize);
            material.SetFloat("_StepCount",     _passSetting.stepCount);
            material.SetFloat("_BinaryCount",   _passSetting.binaryCount);
            material.SetFloat("_StepSize",      _passSetting.stepSize);
            material.SetFloat("_Thickness",     _passSetting.thickness);
            material.SetFloat("_MaxDistance",   _passSetting.maxDistance);
            material.SetFloat("_Roughness",     _passSetting.roughness);
            material.SetFloat("_RandomNum",Random.Range(0, _passSetting.stepCount));
            material.SetTexture("_BlueNoiseTex", _passSetting.bluseNoiseTex);
            material.EnableKeyword("SSR_BINARY_SEARCH");
            material.EnableKeyword("SSR_POTENTIAL_HIT");
            // material.DisableKeyword("SSR_POTENTIAL_HIT");
            // material.DisableKeyword("SSR_BINARY_SEARCH");
            
            ConfigureTarget(targetRT);
            
            var camera = renderingData.cameraData.camera;
            camera.TryGetCullingParameters(out var cullingParameters);
            var cullingResults = context.Cull(ref cullingParameters);
            
            _sortingCriteria = SortingCriteria.RenderQueue;
            _drawingSettings = CreateDrawingSettings(_ShaderTagIdList, ref renderingData, _sortingCriteria);
            _drawingSettings.overrideMaterial = _material;
            _drawingSettings.overrideMaterialPassIndex = 0;
            _filteringSettings = new FilteringSettings(RenderQueueRange.all, _passSetting.m_layerMask.value);
            
            context.DrawRenderers(cullingResults, ref _drawingSettings, ref _filteringSettings);
        }

        private void DoKawaseSample(CommandBuffer cmd, RenderTargetIdentifier sourceid, RenderTargetIdentifier targetid,
                                        Vector2Int sourceSize, Vector2Int targetSize,
                                        float offset, bool downSample, ComputeShader computeShader)
        {
            if (!computeShader) return;
            string kernelName = downSample ? "DualBlurDownSample" : "DualBlurUpSample";
            int kernelID = computeShader.FindKernel(kernelName);
            computeShader.GetKernelThreadGroupSizes(kernelID, out uint x, out uint y, out uint z);
            cmd.SetComputeTextureParam(computeShader, kernelID, "_SourceTex", sourceid);
            cmd.SetComputeTextureParam(computeShader, kernelID, "_RW_TargetTex", targetid);
            cmd.SetComputeVectorParam(computeShader, "_SourceSize", GetTextureSizeParams(sourceSize));
            cmd.SetComputeVectorParam(computeShader, "_TargetSize", GetTextureSizeParams(targetSize));
            cmd.SetComputeFloatParam(computeShader, "_BlurOffset", offset);
            cmd.DispatchCompute(computeShader, kernelID,
                                Mathf.CeilToInt((float)targetSize.x / x),
                                Mathf.CeilToInt((float)targetSize.y / y),
                                1);
        }

        private void DoKawaseLinear(CommandBuffer cmd, RenderTargetIdentifier sourceid, RenderTargetIdentifier targetid,
            Vector2Int sourceSize, float offset, ComputeShader computeShader)
        {
            if (!computeShader) return;
            string kernelName = "LerpDownUpTex";
            int kernelID = computeShader.FindKernel(kernelName);
            computeShader.GetKernelThreadGroupSizes(kernelID, out uint x, out uint y, out uint z);
            cmd.SetComputeTextureParam(computeShader, kernelID, "_SourceTex", sourceid);
            cmd.SetComputeTextureParam(computeShader, kernelID, "_RW_TargetTex", targetid);
            cmd.SetComputeVectorParam(computeShader, "_SourceSize", GetTextureSizeParams(sourceSize));
            cmd.SetComputeFloatParam(computeShader, "_BlurOffset", offset);
            cmd.DispatchCompute(computeShader, kernelID,
                                Mathf.CeilToInt((float)sourceSize.x / x),
                                Mathf.CeilToInt((float)sourceSize.y / y),
                                1);
        }
        
        void Combine(CommandBuffer cmd, ref RenderingData renderingData, ScriptableRenderContext context, RenderTargetIdentifier sourceRT, RenderTargetIdentifier targetRT, Material material)
        {
            if (material == null) return;
            
            ConfigureTarget(sourceRT);
            
            var camera = renderingData.cameraData.camera;
            camera.TryGetCullingParameters(out var cullingParameters);
            var cullingResults = context.Cull(ref cullingParameters);
            
            _sortingCriteria = SortingCriteria.RenderQueue;
            _drawingSettings = CreateDrawingSettings(_ShaderTagIdList, ref renderingData, _sortingCriteria);
            _drawingSettings.overrideMaterial = _material;
            _drawingSettings.overrideMaterialPassIndex = 1;
            _filteringSettings = new FilteringSettings(RenderQueueRange.all);
            
            context.DrawRenderers(cullingResults, ref _drawingSettings, ref _filteringSettings);
            
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
        }
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get(CommandBufferTag);
            
            cmd.Blit(_cameraRT, _cameraColorRT);
            DoSSR(cmd, ref renderingData, context, _OddBuffer, _material);
            
            List<int> rtIDs = new List<int>();
            List<Vector2Int> rtSizes = new List<Vector2Int>();

            RenderTextureDescriptor tempDesc = _descriptor;
            string kawaseRT = "_KawaseRT";
            int kawaseRTID = Shader.PropertyToID(kawaseRT);
            cmd.GetTemporaryRT(kawaseRTID, tempDesc);

            rtIDs.Add(kawaseRTID);
            rtSizes.Add(new Vector2Int((int)_texSize.x, (int)_texSize.y));

            float downSampleAmount = Mathf.Log(_passSetting.GetRadius() + 1.0f) / 0.693147181f;
            int downSampleCount = Mathf.FloorToInt(downSampleAmount);
            float offsetRatio = downSampleAmount - (float)downSampleCount;

            Vector2Int lastSize = new Vector2Int((int)_texSize.x, (int)_texSize.y);
            int lastID = _OddBufferTexID;
            for (int i = 0; i <= downSampleCount; i++)
            {
                string rtName = "_KawaseRT" + i.ToString();
                int rtID = Shader.PropertyToID(rtName);
                Vector2Int rtSize = new Vector2Int((lastSize.x + 1) / 2, (lastSize.y + 1) / 2);
                tempDesc.width = rtSize.x;
                tempDesc.height = rtSize.y;
                cmd.GetTemporaryRT(rtID, tempDesc);

                rtIDs.Add(rtID);
                rtSizes.Add(rtSize);

                DoKawaseSample(cmd, lastID, rtID, lastSize, rtSize, 1.0f, true, _computeShader);
                lastSize = rtSize;
                lastID = rtID;
            }

            if(downSampleCount == 0)
            {
                DoKawaseSample(cmd, rtIDs[1], rtIDs[0], rtSizes[1], rtSizes[0], 1.0f, false, _computeShader);
                DoKawaseLinear(cmd, _cameraColorRT, rtIDs[0], rtSizes[0], offsetRatio, _computeShader);
            }
            else
            {
                string intermediateRTName = "_KawaseRT" + (downSampleCount + 1).ToString();
                int intermediateRTID = Shader.PropertyToID(intermediateRTName);
                Vector2Int intermediateRTSize = rtSizes[downSampleCount];
                tempDesc.width = intermediateRTSize.x;
                tempDesc.height = intermediateRTSize.y;
                cmd.GetTemporaryRT(intermediateRTID, tempDesc);
                
                for (int i = downSampleCount+1; i >= 1; i--)
                {
                    int sourceID = rtIDs[i];
                    Vector2Int sourceSize = rtSizes[i];
                    int targetID = i == (downSampleCount + 1) ? intermediateRTID : rtIDs[i - 1];
                    Vector2Int targetSize = rtSizes[i - 1];
                
                    DoKawaseSample(cmd, sourceID, targetID, sourceSize, targetSize, 1.0f, false, _computeShader);
                
                    if (i == (downSampleCount + 1))
                    {
                        DoKawaseLinear(cmd, rtIDs[i - 1], intermediateRTID, targetSize, offsetRatio, _computeShader);
                        int tempID = intermediateRTID;
                        intermediateRTID = rtIDs[i - 1];
                        rtIDs[i - 1] = tempID;
                    }
                    cmd.ReleaseTemporaryRT(sourceID);
                }
                cmd.ReleaseTemporaryRT(intermediateRTID);
            }
            cmd.Blit(kawaseRTID, _EvenBufferTexID);
            cmd.ReleaseTemporaryRT(kawaseRTID);
            cmd.Blit(null, _cameraRT, _material, 1);
            
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
        
        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            cmd.ReleaseTemporaryRT(_OddBufferTexID);
            cmd.ReleaseTemporaryRT(_EvenBufferTexID);
        }
        #endregion
    }
}