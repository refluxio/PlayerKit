import SwiftUI

public struct PlayerView: View {
    public let player: Player

    public init(player: Player) {
        self.player = player
    }

    public var body: some View {
        PlayerNativeView(player: player)
            .background(Color.black)
    }
}
