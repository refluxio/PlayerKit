import PlayerKit
import Foundation
import Mpv

// MARK: - MPVRenderContext

/// mpv_render_context 生命周期管理。
/// update callback 在 MPV 内部线程调用，只设 flag，不做 UI 操作。
final class MPVRenderContext: @unchecked Sendable {

    private var ctx: OpaquePointer?
    private var _hasNewFrame: Bool = false
    private let lock = NSLock()
    var updateCallbackCount: Int = 0

    /// 当前 render context 的像素格式（创建后不可变更）。
    let pixelFormat: String

    init(core: MPVCore, format: String = "bgra") throws {
        pixelFormat = format
        // MPV_RENDER_API_TYPE_SW is imported as a Swift String ("sw").
        // Use withCString to get a stable C pointer for the duration of the call.
        var createError: Error? = nil
        MPV_RENDER_API_TYPE_SW.withCString { apiPtr in
            format.withCString { fmtPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(
                        type: MPV_RENDER_PARAM_API_TYPE,
                        data: UnsafeMutableRawPointer(mutating: apiPtr)
                    ),
                    mpv_render_param(
                        type: MPV_RENDER_PARAM_SW_FORMAT,
                        data: UnsafeMutableRawPointer(mutating: fmtPtr)
                    ),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                let status = mpv_render_context_create(&ctx, core.handle, &params)
                if status != 0 {
                    createError = PlayerError.renderContextFailed
                }
            }
        }
        if let err = createError { throw err }

        // Update callback: called by MPV internal thread when a new frame is ready.
        // MUST only do minimal work here — no UIKit/AVFoundation calls.
        mpv_render_context_set_update_callback(
            ctx,
            { ctxPtr in
                guard let ctxPtr else { return }
                let renderCtx = Unmanaged<MPVRenderContext>
                    .fromOpaque(ctxPtr)
                    .takeUnretainedValue()
                renderCtx.lock.lock()
                let wasNew = renderCtx._hasNewFrame
                renderCtx._hasNewFrame = true
                renderCtx.updateCallbackCount += 1
                let n = renderCtx.updateCallbackCount
                renderCtx.lock.unlock()
                if n <= 5 || n % 300 == 0 {
                    NSLog("[mpvkit][render] update callback #\(n) wasNew=\(wasNew)")
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Atomically read and reset the hasNewFrame flag.
    func consumeNewFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let v = _hasNewFrame
        _hasNewFrame = false
        return v
    }

    /// Render current frame into the provided buffer using SW renderer.
    /// Returns 0 on success, negative on error/no frame.
    /// - Note: SW_STRIDE expects size_t* (Swift `Int`), SW_SIZE expects int[2] (Swift `[Int32]`).
    @discardableResult
    func render(into buffer: UnsafeMutableRawPointer,
                width: Int, height: Int, bytesPerRow: Int,
                format: String? = nil) -> Int32 {
        let fmt = format ?? pixelFormat
        // SW_SIZE: int[2] — use Int32
        var size: (Int32, Int32) = (Int32(width), Int32(height))
        // SW_STRIDE: size_t* — must be Int (not Int32)
        var stride: Int = bytesPerRow
        return withUnsafeMutableBytes(of: &size) { sizeBuf in
            withUnsafeMutableBytes(of: &stride) { strideBuf in
                fmt.withCString { fmtPtr in
                    var params: [mpv_render_param] = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE,
                                         data: sizeBuf.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                                         data: UnsafeMutableRawPointer(mutating: fmtPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE,
                                         data: strideBuf.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER,
                                         data: buffer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(ctx, &params)
                }
            }
        }
    }

    /// 通知 mpv 一帧已呈现（让 update callback 更快触发，避免 A/V 同步漂移）
    func reportSwap() {
        guard let ctx else { return }
        mpv_render_context_report_swap(ctx)
    }

    deinit {
        if let ctx { mpv_render_context_free(ctx) }
    }
}
