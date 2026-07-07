import QuartzCore
#if os(macOS)
import AppKit
#endif

@MainActor
public final class DisplayBridge {

    public let renderLayer: CALayer
    public var videoWidth:  Int = 0
    public var videoHeight: Int = 0
    public var isReadyToRender = false

    private var displayLink: CADisplayLink?
    private var renderCallback: (() -> Void)?

    public init(renderLayer: CALayer, renderCallback: @escaping () -> Void) {
        self.renderLayer = renderLayer
        self.renderCallback = renderCallback
    }

    public func start() {
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

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    public func pause()  { displayLink?.isPaused = true }
    public func resume() { displayLink?.isPaused = false }
    public func clear()  { renderLayer.opacity = 0 }
    public func flush()  { renderCallback = nil }

    deinit { displayLink?.invalidate() }

    @objc private func tick() {
        let w = videoWidth
        let h = videoHeight
        guard w > 0, h > 0, isReadyToRender else { return }
        renderCallback?()
    }
}
