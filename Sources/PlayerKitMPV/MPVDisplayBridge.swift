import PlayerKit
import QuartzCore
#if os(macOS)
import AppKit
#endif

// MARK: - MPVInternalRenderer

/// Internal protocol combining the public VideoRenderer with mpv-specific renderFrame.
@MainActor
protocol MPVInternalRenderer: VideoRenderer {
    func renderFrame(width: Int, height: Int)
}

// MARK: - DisplayBridge

/// CADisplayLink 驱动的渲染循环。tick → renderer.renderFrame() → 显示。
/// renderer 通过 VideoRenderer 协议抽象，运行时可通过 setRenderer() 切换。
@MainActor
final class MPVDisplayBridge: VideoRenderer {

    /// 要加入视图层级的 layer（由当前 renderer 决定类型）
    var layer: CALayer { renderer.layer }

    var videoWidth:  Int = 0
    var videoHeight: Int = 0
    /// 只有 .fileLoaded 事件后才允许渲染，防止新文件加载过渡期渲染旧视频帧。
    var isReadyToRender = false

    private(set) var renderer: any MPVInternalRenderer
    private var displayLink: CADisplayLink?

    init(renderer: any MPVInternalRenderer) {
        self.renderer = renderer
    }

    // MARK: - VideoRenderer

    func render(pixelBuffer: CVPixelBuffer, pts: Double) {
        // MPV renders via its own callback; CVPixelBuffer delivery not supported
    }

    // MARK: - Lifecycle

    func start() {
        guard displayLink == nil else { return }
#if os(macOS)
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(tick))
            link.add(to: RunLoop.main, forMode: .common)
            displayLink = link
        }
#else
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: RunLoop.main, forMode: .common)
        displayLink = link
#endif
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 暂停渲染循环（方向切换期间调用，避免 nextDrawable 阻塞主线程）
    func pause() {
        displayLink?.isPaused = true
    }

    /// 恢复渲染循环
    func resume() {
        displayLink?.isPaused = false
    }

    func flush() { renderer.flush() }

    func clear() { renderer.clear() }

    func updateColorParams(_ params: VideoColorParams) {
        renderer.updateColorParams(params)
    }

    /// 运行时切换渲染后端（flush 旧 renderer，替换为新的）
    func setRenderer(_ newRenderer: any MPVInternalRenderer) {
        renderer.flush()
        renderer = newRenderer
    }

    deinit { displayLink?.invalidate() }

    // MARK: - Render tick

    @objc private func tick() {
        let w = videoWidth
        let h = videoHeight
        guard w > 0, h > 0, isReadyToRender else { return }
        renderer.renderFrame(width: w, height: h)
    }
}
