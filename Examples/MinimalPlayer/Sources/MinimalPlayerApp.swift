import SwiftUI
import PlayerKit
import PlayerKitNative

@main
struct MinimalPlayerApp: App {
    @State private var player = Player(backend: try! NativeBackend())

    var body: some Scene {
        WindowGroup {
            ContentView(player: player)
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}

struct ContentView: View {
    let player: Player
    @State private var urlText = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Media URL", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                Button("Play") {
                    guard let url = URL(string: urlText) else { return }
                    player.play(url: url, headers: [:], seekTo: nil, knownDuration: nil)
                }
                .disabled(urlText.isEmpty)
            }
            .padding(.horizontal)

            PlayerView(player: player)
                .aspectRatio(16/9, contentMode: .fit)
                .background(.black)
                .cornerRadius(8)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Pause") { player.pause() }
                Button("Resume") { player.resume() }
                Button("Stop") { player.stop() }
            }
        }
        .padding(.vertical)
    }
}
