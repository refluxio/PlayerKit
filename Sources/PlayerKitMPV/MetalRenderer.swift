import PlayerKit
// Packages/MPVKit/Sources/MPVKit/Render/MetalRenderer.swift
import Metal
import CoreVideo
import QuartzCore
import CoreFoundation

// MARK: - MetalRenderer

/// BGRA → CVMetalTextureCache → MTLTexture → Metal passthrough → CAMetalLayer EDR。
/// SW render（MPV_RENDER_API_TYPE_SW，format "bgra"）写入 IOSurface CVPixelBuffer，
/// CVMetalTextureCache 零拷贝包装为 MTLTexture，GPU 完成 gamma→linear 转换后显示。
@MainActor
final class MetalRenderer: MPVInternalRenderer {

    // MARK: - Public

    let metalLayer: CAMetalLayer
    var layer: CALayer { metalLayer }

    // MARK: - Private

    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureCache:  CVMetalTextureCache

    private var pool:          CVPixelBufferPool?
    private var colorParams    = VideoColorParams()
    private let colorParamsBuf: MTLBuffer

    private let renderCtx:     MPVRenderContext
    private var lastWidth  = 0
    private var lastHeight = 0
    private var frameCount = 0

    // MARK: - Init

    init(renderCtx: MPVRenderContext) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PlayerError.metalUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw PlayerError.metalUnavailable
        }
        guard let buf = device.makeBuffer(
            length: MemoryLayout<ColorParamsUniform>.size,
            options: .storageModeShared) else {
            throw PlayerError.metalUnavailable
        }

        self.renderCtx    = renderCtx
        self.device       = device
        self.commandQueue = queue
        self.colorParamsBuf = buf

        // CAMetalLayer 配置
        let ml = CAMetalLayer()
        ml.device        = device
        ml.pixelFormat   = .rgba16Float
        ml.framebufferOnly = true
        ml.allowsNextDrawableTimeout = true
        ml.colorspace    = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ml.contentsGravity = .resizeAspect
#if os(macOS)
        ml.wantsExtendedDynamicRangeContent = true
#endif
        self.metalLayer = ml

        // CVMetalTextureCache
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw PlayerError.metalUnavailable
        }
        self.textureCache = cache

        // Render pipeline
        self.pipelineState = try MetalRenderer.makePipeline(device: device)

        writeColorParams(VideoColorParams())
    }

    // MARK: - VideoRenderer

    func render(pixelBuffer: CVPixelBuffer, pts: Double) {
        // MPV renders via its own callback; CVPixelBuffer delivery not supported
    }

    func renderFrame(width: Int, height: Int) {
        guard renderCtx.consumeNewFrame() else { return }

        ensurePool(width: width, height: height)
        guard let pool else { renderCtx.reportSwap(); return }

        var cvBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &cvBuf) == kCVReturnSuccess,
              let cvBuf else { renderCtx.reportSwap(); return }

        CVPixelBufferLockBaseAddress(cvBuf, [])
        let ok = renderBGRA(into: cvBuf, width: width, height: height)
        CVPixelBufferUnlockBaseAddress(cvBuf, [])

        guard ok else { renderCtx.reportSwap(); return }

        writeColorParams(colorParams)

        // CVMetalTextureCache 零拷贝 → MTLTexture
        guard let tex = makeTexture(from: cvBuf) else { renderCtx.reportSwap(); return }

        guard let drawable = metalLayer.nextDrawable() else { renderCtx.reportSwap(); return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = drawable.texture
        passDesc.colorAttachments[0].loadAction  = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuf  = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { renderCtx.reportSwap(); return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(colorParamsBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(tex, index: 0)
        encoder.setFragmentBuffer(colorParamsBuf, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()

        metalLayer.opacity = 1
        renderCtx.reportSwap()

        frameCount += 1
        if frameCount <= 3 || frameCount % 600 == 0 {
            NSLog("[mpvkit][metal#\(frameCount)] w=\(width) h=\(height)")
        }
    }

    func flush() {
        metalLayer.opacity = 0
        lastWidth = 0; lastHeight = 0
        frameCount = 0
        pool = nil
        CVMetalTextureCacheFlush(textureCache, 0)
        _ = renderCtx.consumeNewFrame()
        renderCtx.reportSwap()
    }

    func clear() {
        metalLayer.opacity = 0
    }

    private func clearDrawable() {
        guard let drawable = metalLayer.nextDrawable(),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: {
                  let desc = MTLRenderPassDescriptor()
                  desc.colorAttachments[0].texture = drawable.texture
                  desc.colorAttachments[0].loadAction = .clear
                  desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                  desc.colorAttachments[0].storeAction = .store
                  return desc
              }()) else { return }
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    func updateColorParams(_ params: VideoColorParams) {
        guard params != colorParams else { return }
        colorParams = params
        writeColorParams(params)
        updateLayerColorspace(params)
    }

    // MARK: - Private helpers

    private func writeColorParams(_ params: VideoColorParams) {
        let ds = metalLayer.drawableSize
        let viewAspect = Double(ds.width) / Double(ds.height).clamped(to: 1...10000)
        let videoAspect = Double(lastWidth) / Double(lastHeight).clamped(to: 1...10000)
        let sx = Float(min(1.0, videoAspect / viewAspect))
        let sy = Float(min(1.0, viewAspect / videoAspect))
        let isDownscaling = (lastWidth > Int(ds.width) || lastHeight > Int(ds.height)) ? Int32(1) : Int32(0)
        var u = ColorParamsUniform(
            transfer: Int32(params.transfer.metalIndex),
            scaleX: sx, scaleY: sy,
            downscaling: isDownscaling)
        memcpy(colorParamsBuf.contents(), &u, MemoryLayout<ColorParamsUniform>.size)
    }

    private func updateLayerColorspace(_ params: VideoColorParams) {
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
#if os(iOS)
        if #available(iOS 16.0, *) {
            switch params.transfer {
            case .pq:
                metalLayer.edrMetadata = CAEDRMetadata.hdr10(
                    minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 1)
            case .hlg:
                metalLayer.edrMetadata = CAEDRMetadata.hlg
            case .sdr:
                metalLayer.edrMetadata = nil
            }
        }
#endif
    }

    /// MPV SW render BGRA 到 CVPixelBuffer
    private func renderBGRA(into buf: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return false }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        return renderCtx.render(into: base, width: width, height: height,
                                bytesPerRow: stride) == 0
    }

    private func ensurePool(width: Int, height: Int) {
        guard width != lastWidth || height != lastHeight else { return }
        lastWidth = width; lastHeight = height
        pool = nil
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey:               width,
            kCVPixelBufferHeightKey:              height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey:  true,
        ]
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            attrs as CFDictionary, &pool)
    }

    private func makeTexture(from buf: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buf, nil, .bgra8Unorm, w, h, 0, &tex)
        return tex.flatMap { CVMetalTextureGetTexture($0) }
    }

    // MARK: - Pipeline

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: kMetalShaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = library.makeFunction(name: "mpv_vertex")
        desc.fragmentFunction = library.makeFunction(name: "mpv_fragment")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        return try device.makeRenderPipelineState(descriptor: desc)
    }
}

// MARK: - Uniform struct

struct ColorParamsUniform {
    var transfer:      Int32  // 0=sdr, 1=pq, 2=hlg
    var scaleX:        Float32
    var scaleY:        Float32
    var downscaling:   Int32  // 1 when video > display
}

// MARK: - metalIndex helpers

extension VideoColorParams.TransferFunc {
    var metalIndex: Int { switch self { case .sdr: 0; case .pq: 1; case .hlg: 2 } }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Metal shader source

let kMetalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    int   transfer;
    float scaleX;
    float scaleY;
    int   downscaling;
};

vertex VertexOut mpv_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    const float2 pos[6] = {
        {-1,-1}, { 1,-1}, {-1, 1},
        { 1,-1}, { 1, 1}, {-1, 1}
    };
    const float2 uv[6] = {
        {0,1}, {1,1}, {0,0},
        {1,1}, {1,0}, {0,0}
    };
    VertexOut out;
    out.position = float4(pos[vid].x * u.scaleX, pos[vid].y * u.scaleY, 0, 1);
    out.texCoord = uv[vid];
    return out;
}

fragment half4 mpv_fragment(
    VertexOut             in [[stage_in]],
    texture2d<float, access::sample> tex [[texture(0)]],
    constant Uniforms&    p   [[buffer(0)]]
) {
    float3 rgb;

    if (p.downscaling != 0) {
        // Downscaling: linear — averages 2x2 source pixels, no aliasing
        constexpr sampler sm(filter::linear, address::clamp_to_edge);
        rgb = tex.sample(sm, in.texCoord).rgb;
    } else {
        // Upscaling: Catmull-Rom bicubic — sharp, ~free on GPU
        constexpr sampler sn(filter::nearest, address::clamp_to_edge);
        float2 texSize = float2(tex.get_width(), tex.get_height());
        float2 pixCoord = in.texCoord * texSize - 0.5f;
        float2 p0 = floor(pixCoord);
        float2 f  = fract(pixCoord);

        auto cr = [](float x) -> float {
            float ax = abs(x);
            if (ax <= 1.0f) return 1.0f - 2.5f*x*x + 1.5f*ax*ax*ax;
            if (ax <  2.0f) return 2.0f - 4.0f*ax + 2.5f*x*x - 0.5f*ax*ax*ax;
            return 0.0f;
        };

        rgb = float3(0.0f);
        for (int j = -1; j <= 2; j++) {
            for (int i = -1; i <= 2; i++) {
                float2 offset = float2(float(i), float(j));
                float w = cr(f.x - float(i)) * cr(f.y - float(j));
                float2 uv = (p0 + offset + 0.5f) / texSize;
                rgb += tex.sample(sn, uv).rgb * w;
            }
        }
    }

    if (p.transfer == 0) {
        rgb = pow(max(rgb, 0.0f), 2.2f);
    }

    return half4(half3(rgb), 1.0h);
}
"""
