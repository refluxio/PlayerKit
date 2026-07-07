# PlayerKit

A protocol-oriented, FFmpeg + VideoToolbox + Metal media player SDK for Apple platforms.

## Features

- **Protocol-oriented** — `Playable`, `MediaProbable`, `FrameSink`, `VideoRenderer`, `PlayerBackend`, `AudioOutputBackend`. Replace any layer with your own implementation.
- **Native hardware decoding** — VideoToolbox for H.264/H.265, FFmpeg software decode fallback.
- **A/V sync** — AudioClock-driven master clock with VideoJitterBuffer de-jitter and SyncController adaptive speed.
- **Bundled FFmpeg 8.1.2** — 5 xcframeworks (82 MB) checked into the repo. Clone and build — no build script required.
- **HDR → SDR tone-mapping** — PQ/HLG to BT.709 via Metal compute shader.

## Requirements

- macOS 14+ / iOS 17+ / tvOS 17+
- Xcode 16+
- Swift 5.9+

## Installation

Add PlayerKit as a Swift Package Manager dependency:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/refluxio/PlayerKit.git", from: "0.1.0")
]
```

Then add `PlayerKit` and `PlayerKitNative` to your target:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "PlayerKit", package: "PlayerKit"),
    .product(name: "PlayerKitNative", package: "PlayerKit"),
])
```

## Quick Start

```swift
import PlayerKit
import PlayerKitNative
import SwiftUI

struct ContentView: View {
    let player = Player(backend: try! NativeBackend())

    var body: some View {
        VStack {
            PlayerView(player: player)
            Button("Play") {
                player.play(
                    url: URL(string: "https://example.com/video.mkv")!,
                    headers: [:],
                    seekTo: nil,
                    knownDuration: nil
                )
            }
        }
    }
}
```

## Examples

See [Examples/MinimalPlayer/](Examples/MinimalPlayer/) for a standalone macOS app.

## License

LGPL v2.1+. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

PlayerKit dynamically links FFmpeg (also LGPL v2.1+). You may replace the bundled FFmpeg xcframeworks with your own build to comply with LGPL.

## Related

- [reflux.io](https://reflux.io) — The media server that uses PlayerKit.
