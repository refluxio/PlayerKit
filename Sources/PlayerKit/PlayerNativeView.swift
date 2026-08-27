import AVFoundation
import SwiftUI

#if os(macOS)
import AppKit

@MainActor
public final class PlayerNativeViewMac: NSView {
    private let player: Player

    init(player: Player) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        // Dark backdrop behind the video so letterbox bars blend with the
        // window chrome instead of showing a bright background peeking through.
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(player.renderLayer ?? CALayer())
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Set contentsScale once when the view is attached to a window — not in
        // layout(). Writing contentsScale on every layout() forces CAMetalLayer
        // to recompute its drawable-to-contents mapping and triggers implicit
        // geometry invalidation, which shows up as jitter even inside a
        // CATransaction with actions disabled.
        guard let ml = player.renderLayer as? CAMetalLayer else { return }
        ml.contentsScale = window?.backingScaleFactor ?? 1.0
    }

    override public func layout() {
        super.layout()
        let target = player.renderLayer ?? CALayer()
        if layer?.sublayers?.first !== target {
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer?.addSublayer(target)
        }
        let frame: CGRect
        if target is AVSampleBufferDisplayLayer {
            // Size the display layer to the video's actual aspect-ratio rect within
            // the view bounds (same as the iOS variant).  The parent view (black
            // background) provides the letterbox/pillarbox bars.  This is essential
            // for PiP: the PiP window keeps the video's proportions, and when the
            // user returns from PiP the system animates the PiP window back to the
            // layer's frame — if the layer spans the full view bounds (arbitrary
            // window aspect), the animation target proportion mismatches the video
            // and the picture visibly stretches for a moment before aspect-fit
            // restores it.
            frame = videoLayerFrame(in: bounds, videoInfo: player.state.videoInfo)
            (target as? AVSampleBufferDisplayLayer)?.videoGravity =
                (frame == bounds) ? .resizeAspect : .resize
        } else {
            // Non-ASBDL renderers (e.g. Metal) manage their own content rect.
            // Without this, the CAMetalLayer can end up with a zero or stale frame
            // and the video appears shrunken in the top-left corner instead of
            // filling the view.
            frame = bounds
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.frame = frame
        CATransaction.commit()
    }

    private func videoLayerFrame(in bounds: CGRect, videoInfo: VideoInfo?) -> CGRect {
        guard let info = videoInfo, info.width > 0, info.height > 0 else { return bounds }
        let aspect = CGFloat(info.width) / CGFloat(info.height)
        let boundsAspect = bounds.width / bounds.height
        if aspect > boundsAspect {
            // Letterbox: black bars top and bottom
            let h = bounds.width / aspect
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            // Pillarbox: black bars left and right
            let w = bounds.height * aspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
    }
}

public struct PlayerNativeView: NSViewRepresentable {
    public let player: Player
    public init(player: Player) { self.player = player }

    @MainActor
    public func makeNSView(context: Context) -> PlayerNativeViewMac {
        PlayerNativeViewMac(player: player)
    }

    public func updateNSView(_ nsView: PlayerNativeViewMac, context: Context) {
        // Reading videoInfo here registers SwiftUI observation tracking.
        // When videoInfo changes (video opens), SwiftUI re-calls updateNSView,
        // which triggers layout so the display layer is resized to the video's
        // aspect-ratio rect (see layout()).
        _ = player.state.videoInfo
        nsView.needsLayout = true
    }
}

#elseif os(iOS) || os(tvOS)
import UIKit

@MainActor
public final class PlayerNativeViewiOS: UIView {
    private let player: Player
    #if os(iOS)
    private var lifecycleTokens: [NSObjectProtocol] = []
    #endif

    init(player: Player) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(player.renderLayer ?? CALayer())
        #if os(iOS)
        // PiP 激活时系统把 displayLayer 接入自己的渲染树,可能改动其 frame;
        // 从 PiP 恢复时系统把 PiP 窗口动画回 contentSource layer 的 frame ——
        // 若此时 frame 不是视频比例矩形,画面会在动画期间被拉伸放大、动画
        // 结束才回缩("先放大一下,然后瞬间恢复",与 macOS layout() 修的同一
        // 问题)。这里在 PiP 激活/停止与 app 回前台时强制重算 frame,保证
        // 恢复动画开始前 frame 已是视频比例矩形。
        let center = NotificationCenter.default
        lifecycleTokens.append(center.addObserver(
            forName: .playerKitPiPDidStart, object: nil, queue: .main
        ) { [weak self] _ in self?.setNeedsLayout() })
        lifecycleTokens.append(center.addObserver(
            forName: .playerKitPiPDidStop, object: nil, queue: .main
        ) { [weak self] _ in self?.setNeedsLayout() })
        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.setNeedsLayout() })
        #endif
    }

    deinit {
        #if os(iOS)
        lifecycleTokens.forEach { NotificationCenter.default.removeObserver($0) }
        #endif
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        // Set contentsScale once when the view is attached to a window — not in
        // layoutSubviews(). See macOS variant for rationale: writing contentsScale
        // on every layout pass forces CAMetalLayer to recompute its drawable-to-
        // contents mapping and triggers implicit geometry invalidation → jitter.
        guard window != nil, let ml = player.renderLayer as? CAMetalLayer else { return }
        contentScaleFactor = window!.screen.scale
        ml.contentsScale = window!.screen.scale
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let target = player.renderLayer ?? CALayer()
        if layer.sublayers?.first !== target {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.addSublayer(target)
        }
        // Size the display layer to the video's actual aspect-ratio rect within the
        // view bounds.  The parent view (black background) provides the letterbox/
        // pillarbox bars.  This is essential for PiP: the PiP window size is
        // determined by the content source layer's bounds, not the pixel buffer
        // dimensions — using a full-screen layer causes the PiP window to appear
        // the same size as the portrait device screen.
        let frame = videoLayerFrame(in: bounds, videoInfo: player.state.videoInfo)
        if let dl = target as? AVSampleBufferDisplayLayer {
            // .resize fills the layer exactly when sized to the video rect;
            // .resizeAspect is used as fallback (before video info is known).
            dl.videoGravity = (frame == bounds) ? .resizeAspect : .resize
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.frame = frame
        CATransaction.commit()
    }

    private func videoLayerFrame(in bounds: CGRect, videoInfo: VideoInfo?) -> CGRect {
        guard let info = videoInfo, info.width > 0, info.height > 0 else { return bounds }
        let aspect = CGFloat(info.width) / CGFloat(info.height)
        let boundsAspect = bounds.width / bounds.height
        if aspect > boundsAspect {
            // Letterbox: black bars top and bottom
            let h = bounds.width / aspect
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            // Pillarbox: black bars left and right
            let w = bounds.height * aspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
    }
}

public struct PlayerNativeView: UIViewRepresentable {
    public let player: Player
    public init(player: Player) { self.player = player }

    @MainActor
    public func makeUIView(context: Context) -> PlayerNativeViewiOS {
        PlayerNativeViewiOS(player: player)
    }

    public func updateUIView(_ uiView: PlayerNativeViewiOS, context: Context) {
        // Reading videoInfo here registers SwiftUI observation tracking.
        // When videoInfo changes (video opens), SwiftUI re-calls updateUIView,
        // which triggers setNeedsLayout so the display layer is resized to the
        // correct video aspect ratio for PiP.
        _ = player.state.videoInfo
        uiView.setNeedsLayout()
    }
}
#endif
