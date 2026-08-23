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
    /// User-adjustable scale factor for subtitle size (1.0 = original, 1.5 = 50% larger, 0.8 = 20% smaller).
    public var scale: CGFloat = 1.0

    public init(player: Player, verticalOffset: CGFloat = 0, horizontalOffset: CGFloat = 0, scale: CGFloat = 1.0) {
        self.player = player
        self.verticalOffset = verticalOffset
        self.horizontalOffset = horizontalOffset
        self.scale = scale
    }

    public var body: some View {
        GeometryReader { geo in
            let videoRect = videoDisplayRect(in: geo)
            // Use videoRect as the alignment frame so subtitles align to the
            // bottom of the video (not the full screen). In portrait with
            // letterbox bars, the video is centered — aligning to screen
            // bottom would put subtitles in the bottom black bar, not on
            // the video.
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
            .frame(width: videoRect.width, height: videoRect.height, alignment: .bottom)
            .position(x: videoRect.midX, y: videoRect.midY)
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
            .font(.system(size: 20 * scale, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(4 * scale)
            .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: 1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: 1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: -1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: -1)
            .shadow(color: .black.opacity(0.6),  radius: 3 * scale)
            .padding(.horizontal, 24)
            .frame(maxWidth: videoRect.width - 16)
            .padding(.bottom, 20)
            .offset(x: horizontalOffset, y: verticalOffset)
    }

    private func bitmapSubtitle(_ image: CGImage, rect: CGRect,
                                in geo: GeometryProxy, videoRect: CGRect) -> some View {
        // Center the bitmap subtitle horizontally within the video rect,
        // placed at the bottom (same layout as text subtitles).
        // Ignore PGS's original x/y — BD placement is often off-center.
        let scaledWidth = rect.width * videoRect.width * scale
        let scaledHeight = rect.height * videoRect.height * scale
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: scaledWidth, height: scaledHeight)
            .padding(.bottom, 20)
            .offset(x: horizontalOffset, y: verticalOffset)
    }
}
