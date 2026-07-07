import PlayerKit
#if os(iOS) || os(tvOS)
import CoreFoundation
import CoreVideo
import Metal
import OpenGLES
import QuartzCore

// MARK: - GLMetalRenderer

/// OpenGL render → CVPixelBuffer → Metal display。
/// mpv OpenGL render API（零拷贝 VideoToolbox 硬解）→ CVPixelBuffer（IOSurface 共享）→
/// CVMetalTextureCache → MTLTexture → Metal shader → CAMetalLayer EDR。
@MainActor
final class GLMetalRenderer: MPVInternalRenderer {

    // MARK: - Public

    let metalLayer: CAMetalLayer
    var layer: CALayer { metalLayer }

    // MARK: - Private

    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let metalTextureCache: CVMetalTextureCache
    private let glRenderCtx:   OpenGLRenderContext

    private var colorParams    = VideoColorParams()
    private let colorParamsBuf: MTLBuffer
    private var lastWidth  = 0
    private var lastHeight = 0
    private var frameCount = 0
    private var needsClear = false

    // GL frame buffers (triple-buffered)
    private var glFrames: [GLFrame] = []
    private var frameIndex = 0

    private struct GLFrame {
        let pixelBuffer: CVPixelBuffer
        let glTexture: CVOpenGLESTexture
        let fbo: GLuint
    }

    // MARK: - Init

    init(renderCtx: OpenGLRenderContext) throws {
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

        self.glRenderCtx     = renderCtx
        self.device          = device
        self.commandQueue    = queue
        self.colorParamsBuf  = buf

        let ml = CAMetalLayer()
        ml.device        = device
        ml.pixelFormat   = .rgba16Float
        ml.framebufferOnly = true
        ml.allowsNextDrawableTimeout = true
        ml.colorspace    = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ml.contentsGravity = .resizeAspect
        self.metalLayer = ml

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw PlayerError.metalUnavailable
        }
        self.metalTextureCache = cache

        self.pipelineState = try Self.makePipeline(device: device)
        writeColorParams(VideoColorParams())
    }

    // MARK: - VideoRenderer

    func render(pixelBuffer: CVPixelBuffer, pts: Double) {
        // MPV renders via its own callback; CVPixelBuffer delivery not supported
    }

    func renderFrame(width: Int, height: Int) {
        // 用物理像素分辨率创建 FBO — bounds × contentsScale
        let scale = max(1.0, metalLayer.contentsScale)
        let fboW = max(1, Int(metalLayer.bounds.width  * scale))
        let fboH = max(1, Int(metalLayer.bounds.height * scale))

        // drawableSize 必须和 FBO 一致，否则 nextDrawable 尺寸不匹配
        let ds = metalLayer.drawableSize
        if Int(ds.width) != fboW || Int(ds.height) != fboH {
            metalLayer.drawableSize = CGSize(width: fboW, height: fboH)
        }

        // 尺寸变化时重建 FBO，然后继续渲染（不 return early）
        if fboW != lastWidth || fboH != lastHeight {
            NSLog("[mpvkit][gl-metal] size change: \(lastWidth)x\(lastHeight) → \(fboW)x\(fboH)")
            ensureGLFrames(width: fboW, height: fboH)
        }

        guard glRenderCtx.consumeNewFrame() else {
            // 没有新帧时，如果需要清除上一视频残留画面，呈现黑帧
            if needsClear { presentBlackFrame(); needsClear = false }
            return
        }
        needsClear = false

        guard !glFrames.isEmpty else {
            lastWidth = 0; lastHeight = 0
            glRenderCtx.reportSwap()
            return
        }

        let frame = glFrames[frameIndex % glFrames.count]
        frameIndex += 1

        // mpv OpenGL render → FBO（屏幕分辨率，mpv 处理缩放+宽高比）
        EAGLContext.setCurrent(glRenderCtx.eaglCtx)
        let ok = glRenderCtx.render(toFBO: frame.fbo, width: fboW, height: fboH)
        glFlush()
        EAGLContext.setCurrent(nil)

        guard ok else { glRenderCtx.reportSwap(); return }

        // mpv 已处理缩放 → Metal 1:1 显示
        writeColorParamsGL()

        // CVPixelBuffer → MTLTexture（零拷贝共享 IOSurface）
        guard let tex = makeTexture(from: frame.pixelBuffer) else {
            glRenderCtx.reportSwap()
            return
        }

        guard let drawable = metalLayer.nextDrawable() else {
            glRenderCtx.reportSwap()
            return
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = drawable.texture
        passDesc.colorAttachments[0].loadAction  = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuf  = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else {
            glRenderCtx.reportSwap()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(colorParamsBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(tex, index: 0)
        encoder.setFragmentBuffer(colorParamsBuf, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()

        metalLayer.opacity = 1
        glRenderCtx.reportSwap()

        frameCount += 1
        if frameCount <= 3 || frameCount % 600 == 0 {
            NSLog("[mpvkit][gl-metal#\(frameCount)] fbo=\(fboW)x\(fboH) video=\(width)x\(height)")
        }
    }

    func flush() {
        metalLayer.opacity = 0
        lastWidth = 0; lastHeight = 0
        frameCount = 0
        needsClear = true
        destroyGLFrames()
        CVMetalTextureCacheFlush(metalTextureCache, 0)
        CVOpenGLESTextureCacheFlush(glRenderCtx.textureCache, 0)
        _ = glRenderCtx.consumeNewFrame()
        glRenderCtx.reportSwap()
    }

    func clear() {
        metalLayer.opacity = 0
    }

    func updateColorParams(_ params: VideoColorParams) {
        guard params != colorParams else { return }
        colorParams = params
        writeColorParams(params)
        updateLayerColorspace(params)
    }

    // MARK: - GL frame buffer management

    private func ensureGLFrames(width: Int, height: Int) {
        guard width != lastWidth || height != lastHeight else { return }

        var newFrames: [GLFrame] = []
        for i in 0..<3 {
            if let frame = createGLFrame(width: width, height: height) {
                newFrames.append(frame)
            } else {
                NSLog("[mpvkit][gl-metal] GLFrame #\(i) creation failed for \(width)x\(height)")
            }
        }

        if newFrames.isEmpty {
            lastWidth = 0; lastHeight = 0
            return
        }

        destroyGLFrames()
        glFrames = newFrames
        lastWidth = width; lastHeight = height
    }

    private func createGLFrame(width: Int, height: Int) -> GLFrame? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferOpenGLESCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let cvret = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pixelBuffer)
        guard cvret == kCVReturnSuccess, let pixelBuffer else {
            NSLog("[mpvkit][gl-metal] CVPixelBufferCreate failed: \(cvret)")
            return nil
        }

        EAGLContext.setCurrent(glRenderCtx.eaglCtx)
        defer { EAGLContext.setCurrent(nil) }

        var glTexture: CVOpenGLESTexture?
        let texRet = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, glRenderCtx.textureCache, pixelBuffer, nil,
            GLenum(GL_TEXTURE_2D), GL_RGBA,
            GLsizei(width), GLsizei(height),
            GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE),
            0, &glTexture)
        guard texRet == kCVReturnSuccess, let glTexture else {
            NSLog("[mpvkit][gl-metal] CVOpenGLESTextureCacheCreateTextureFromImage failed: \(texRet)")
            return nil
        }

        let textureName = CVOpenGLESTextureGetName(glTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), textureName)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        var fbo: GLuint = 0
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_2D), textureName, 0)
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)

        if status != GLenum(GL_FRAMEBUFFER_COMPLETE) {
            NSLog("[mpvkit][gl-metal] framebuffer incomplete: \(status)")
            var fboDel = fbo
            glDeleteFramebuffers(1, &fboDel)
            return nil
        }

        return GLFrame(pixelBuffer: pixelBuffer, glTexture: glTexture, fbo: fbo)
    }

    private func destroyGLFrames() {
        guard !glFrames.isEmpty else { return }
        EAGLContext.setCurrent(glRenderCtx.eaglCtx)
        for frame in glFrames {
            var fbo = frame.fbo
            glDeleteFramebuffers(1, &fbo)
        }
        EAGLContext.setCurrent(nil)
        glFrames = []
        frameIndex = 0
        CVOpenGLESTextureCacheFlush(glRenderCtx.textureCache, 0)
    }

    // MARK: - Metal helpers

    private func presentBlackFrame() {
        guard let drawable = metalLayer.nextDrawable() else {
            NSLog("[mpvkit][gl-metal] presentBlackFrame: nextDrawable=nil, size=\(metalLayer.drawableSize)")
            return
        }
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
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
        NSLog("[mpvkit][gl-metal] presentBlackFrame: ok")
    }

    /// mpv 已将视频缩放到屏幕分辨率 → Metal 1:1 显示，不做额外缩放
    private func writeColorParamsGL() {
        var u = ColorParamsUniform(
            transfer: Int32(colorParams.transfer.metalIndex),
            scaleX: 1.0, scaleY: 1.0,
            downscaling: 0)
        memcpy(colorParamsBuf.contents(), &u, MemoryLayout<ColorParamsUniform>.size)
    }

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

    private func makeTexture(from buf: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, metalTextureCache, buf, nil, .bgra8Unorm, w, h, 0, &tex)
        return tex.flatMap { CVMetalTextureGetTexture($0) }
    }

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: kMetalShaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = library.makeFunction(name: "mpv_vertex")
        desc.fragmentFunction = library.makeFunction(name: "mpv_fragment")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        return try device.makeRenderPipelineState(descriptor: desc)
    }
}
#endif
