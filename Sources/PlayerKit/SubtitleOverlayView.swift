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
    /// User-adjustable vertical offset in points (positive = move down, negative = move up).
    public var verticalOffset: CGFloat = 0
    /// User-adjustable horizontal offset in points (positive = move right, negative = move left).
    public var horizontalOffset: CGFloat = 0

    public init(player: Player, verticalOffset: CGFloat = 0, horizontalOffset: CGFloat = 0) {
        self.player = player
        self.verticalOffset = verticalOffset
        self.horizontalOffset = horizontalOffset
    }

    public var body: some View {
        GeometryReader { geo in
            let videoRect = videoDisplayRect(in: geo)
            ZStack(alignment: .bottom) {
                if let text = player.state.currentSubtitleText {
                    textSubtitle(text, videoRect: videoRect)
                        .transition(.opacity)
                }
                if let image = player.state.currentSubtitleImage {
                    bitmapSubtitle(image, rect: player.state.currentSubtitleImageRect,
                                   in: geo, videoRect: videoRect)
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.12), value: player.state.currentSubtitleText)
        .animation(.easeInOut(duration: 0.12), value: player.state.currentSubtitleImage != nil)
    }

    /// Compute the actual video display rect (aspect-fit) within the overlay's geometry.
    /// PGS subtitle normalized coordinates are relative to the video frame, not the full
    /// screen — without mapping to the letterboxed rect, subtitles drift off-screen when
    /// the video is pillarboxed/letterboxed (especially in landscape on phones).
    private func videoDisplayRect(in geo: GeometryProxy) -> CGRect {
        guard let info = player.state.videoInfo,
              info.width > 0, info.height > 0 else {
            return CGRect(origin: .zero, size: geo.size)
        }
        let aspect = CGFloat(info.width) / CGFloat(info.height)
        let boundsAspect = geo.size.width / geo.size.height
        if aspect > boundsAspect {
            let h = geo.size.width / aspect
            return CGRect(x: 0,
                          y: (geo.size.height - h) / 2,
                          width: geo.size.width, height: h)
        } else {
            let w = geo.size.height * aspect
            return CGRect(x: (geo.size.width - w) / 2,
                          y: 0,
                          width: w, height: geo.size.height)
        }
    }

    private func textSubtitle(_ text: String, videoRect: CGRect) -> some View {
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
            .padding(.horizontal, 24)
            .frame(maxWidth: videoRect.width - 16)
            .padding(.bottom, 20)
            .offset(x: horizontalOffset, y: verticalOffset)
    }

    private func bitmapSubtitle(_ image: CGImage, rect: CGRect,
                                in geo: GeometryProxy, videoRect: CGRect) -> some View {
        let frame = CGRect(
            x: videoRect.origin.x + rect.origin.x * videoRect.width,
            y: videoRect.origin.y + rect.origin.y * videoRect.height,
            width: rect.width * videoRect.width,
            height: rect.height * videoRect.height
        )
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX + horizontalOffset, y: frame.midY + verticalOffset)
    }
}
