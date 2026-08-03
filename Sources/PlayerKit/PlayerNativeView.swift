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
        // Pin the render layer to the view's full bounds. Without this, the
        // CAMetalLayer can end up with a zero or stale frame and the video
        // appears shrunken in the top-left corner instead of filling the view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.frame = bounds
        CATransaction.commit()
    }
}

public struct PlayerNativeView: NSViewRepresentable {
    public let player: Player
    public init(player: Player) { self.player = player }

    @MainActor
    public func makeNSView(context: Context) -> PlayerNativeViewMac {
        PlayerNativeViewMac(player: player)
    }

    public func updateNSView(_ nsView: PlayerNativeViewMac, context: Context) {}
}

#elseif os(iOS) || os(tvOS)
import UIKit

@MainActor
public final class PlayerNativeViewiOS: UIView {
    private let player: Player

    init(player: Player) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(player.renderLayer ?? CALayer())
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
