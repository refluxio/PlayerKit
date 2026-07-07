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
        layer?.addSublayer(player.renderLayer ?? CALayer())
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    override public func layout() {
        super.layout()
        let target = player.renderLayer ?? CALayer()
        if layer?.sublayers?.first !== target {
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer?.addSublayer(target)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.frame = bounds
        if let ml = target as? CAMetalLayer {
            let scale = window?.backingScaleFactor ?? 1.0
            ml.drawableSize = CGSize(width: bounds.width * scale,
                                     height: bounds.height * scale)
        }
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
        if window != nil {
            contentScaleFactor = window!.screen.scale
            updateMetalLayer()
        }
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let target = player.renderLayer ?? CALayer()
        if layer.sublayers?.first !== target {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.addSublayer(target)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.frame = bounds
        updateMetalLayer()
        CATransaction.commit()
    }

    private func updateMetalLayer() {
        guard let ml = player.renderLayer as? CAMetalLayer else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        ml.contentsScale = scale
        ml.drawableSize = CGSize(
            width:  bounds.width  * scale,
            height: bounds.height * scale)
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
