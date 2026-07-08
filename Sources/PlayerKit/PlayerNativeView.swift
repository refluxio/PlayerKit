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
        // Only set frame here; drawableSize is owned by MetalRenderer.display()
        // (it syncs to the video source dimensions). contentsScale is owned by
        // didMoveToWindow() — see comment there.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.frame = bounds
        CATransaction.commit()
    }
}

public struct PlayerNativeView: UIViewRepresentable {
    public let player: Player
    public init(player: Player) { self.player = player }

    @MainActor
    public func makeUIView(context: Context) -> PlayerNativeViewiOS {
        PlayerNativeViewiOS(player: player)
    }

    public func updateUIView(_ uiView: PlayerNativeViewiOS, context: Context) {}
}
#endif
