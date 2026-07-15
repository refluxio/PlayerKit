import SwiftUI

/// Transparent subtitle overlay. Place on top of PlayerView in a ZStack:
/// ```swift
/// ZStack {
///     PlayerView(player: player)
///     SubtitleOverlayView(player: player)
/// }
/// ```
public struct SubtitleOverlayView: View {
    public let player: Player

    public init(player: Player) { self.player = player }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let text = player.state.currentSubtitleText {
                    textSubtitle(text)
                        .transition(.opacity)
                }
                if let image = player.state.currentSubtitleImage {
                    bitmapSubtitle(image, in: geo)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.12), value: player.state.currentSubtitleText)
    }

    private func textSubtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: 1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: 1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: -1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: -1)
            .shadow(color: .black.opacity(0.6),  radius: 3)
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
    }

    private func bitmapSubtitle(_ image: CGImage, in geo: GeometryProxy) -> some View {
        let r = player.state.currentSubtitleImageRect
        let frame = CGRect(
            x: r.origin.x * geo.size.width,
            y: r.origin.y * geo.size.height,
            width: r.width * geo.size.width,
            height: r.height * geo.size.height
        )
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}
