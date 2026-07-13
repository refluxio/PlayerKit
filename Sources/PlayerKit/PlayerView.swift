import SwiftUI

public struct PlayerView: View {
    public let player: Player

    public init(player: Player) {
        self.player = player
    }

    public var body: some View {
        PlayerNativeView(player: player)
            .background(Color.black)
            .overlay(alignment: .bottom) {
                if let text = player.state.currentSubtitleText {
                    Text(text)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        // Four-direction black outline for readability on any background
                        .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: 1)
                        .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: 1)
                        .shadow(color: .black.opacity(0.95), radius: 0, x: 1,  y: -1)
                        .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: -1)
                        .shadow(color: .black.opacity(0.6),  radius: 3)
                        .padding(.horizontal, 60)
                        .padding(.bottom, 60)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: player.state.currentSubtitleText)
    }
}
