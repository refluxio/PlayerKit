import PlayerKit
#if os(iOS) || os(tvOS)
import CoreVideo
import Foundation
import OpenGLES
import Mpv

// MARK: - OpenGLRenderContext

/// mpv OpenGL render context（iOS/tvOS）。
/// EAGLContext + CVOpenGLESTextureCache + MPV_RENDER_API_TYPE_OPENGL，
/// VideoToolbox → OpenGL 零拷贝硬解路径。
final class OpenGLRenderContext: @unchecked Sendable {

    private var ctx: OpaquePointer?
    private let eaglContext: EAGLContext
    let textureCache: CVOpenGLESTextureCache

    var eaglCtx: EAGLContext { eaglContext }

    init(core: MPVCore) throws {
        guard let context = EAGLContext(api: .openGLES3) else {
            NSLog("[mpvkit][gl] EAGLContext(api: .openGLES3) failed")
            throw PlayerError.renderContextFailed
        }
        self.eaglContext = context

        var cache: CVOpenGLESTextureCache?
        let cvret = CVOpenGLESTextureCacheCreate(
            kCFAllocatorDefault, nil, context, nil, &cache)
        guard cvret == kCVReturnSuccess, let cache else {
            NSLog("[mpvkit][gl] CVOpenGLESTextureCacheCreate failed: \(cvret)")
            throw PlayerError.renderContextFailed
        }
        self.textureCache = cache

        // mpv OpenGL render context 创建必须在 EAGLContext current 状态下
        EAGLContext.setCurrent(context)
        defer { EAGLContext.setCurrent(nil) }

        let apiType = UnsafeMutableRawPointer(
            mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String
        )

        let getProcAddr: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name else { return nil }
            let symbol = CFStringCreateWithCString(
                kCFAllocatorDefault, name, kCFStringEncodingASCII)
            let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString)
            let addr = CFBundleGetFunctionPointerForName(bundle, symbol)
            if addr == nil {
                NSLog("[mpvkit][gl] get_proc_address: not found: \(String(cString: name))")
            }
            return addr
        }

        var procParams = mpv_opengl_init_params(
            get_proc_address: getProcAddr,
            get_proc_address_ctx: nil
        )

        var params: [mpv_render_param] = withUnsafeMutableBytes(of: &procParams) { pb in
            [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(
                    type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                    data: pb.baseAddress.map { UnsafeMutableRawPointer($0) }
                ),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
        }

        let status = mpv_render_context_create(&ctx, core.handle, &params)
        if status != 0 {
            NSLog("[mpvkit][gl] mpv_render_context_create failed: \(status) \(String(cString: mpv_error_string(status)))")
            throw PlayerError.renderContextFailed
        }
    }

    func consumeNewFrame() -> Bool {
        guard let ctx else { return false }
        let flags = mpv_render_context_update(ctx)
        return flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
    }

    /// 渲染当前帧到指定的 OpenGL FBO。
    /// 调用前必须 EAGLContext.setCurrent(eaglContext)。
    func render(toFBO fbo: GLuint, width: Int, height: Int) -> Bool {
        var fboParam = mpv_opengl_fbo(
            fbo: Int32(fbo),
            w: Int32(width),
            h: Int32(height),
            internal_format: 0
        )
        let fboPtr = withUnsafeMutablePointer(to: &fboParam) { $0 }

        // 禁止 mpv 在 render 调用中阻塞等待时序（CADisplayLink 已控制帧率）
        var blockForTime: Int32 = 0

        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: &blockForTime),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]

        let rc = mpv_render_context_render(ctx, &params)
        if rc != 0 {
            NSLog("[mpvkit][gl] mpv_render_context_render failed: \(rc)")
            return false
        }
        return true
    }

    /// 通知 mpv 一帧已呈现（让 update callback 更快触发，避免 A/V 同步漂移）
    func reportSwap() {
        guard let ctx else { return }
        mpv_render_context_report_swap(ctx)
    }

    deinit {
        if let ctx {
            mpv_render_context_set_update_callback(ctx, nil, nil)
            mpv_render_context_free(ctx)
        }
    }
}
#endif
