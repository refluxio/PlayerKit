// MinimalPlayer — a macOS demo of PlayerKit + PlayerKitNative.
//
// VLC-style UI: video fills the window, controls float over the bottom
// in a translucent bar.

import SwiftUI
import PlayerKit
import PlayerKitNative
import UniformTypeIdentifiers

private extension Duration {
    var toDoubleSeconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}

@main
struct MinimalPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            PlayerWindow()
                .frame(minWidth: 480, minHeight: 300)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open File…") { AppActions.pickFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open URL…")  { AppActions.showURLPanel() }
                    .keyboardShortcut("u", modifiers: .command)
            }
        }
    }
}

enum AppActions {
    static func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audiovisualContent, .movie, .video, .audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        NotificationCenter.default.post(name: .openURLSubmitted, object: url)
    }

    /// Post a notification; PlayerWindow presents an inline sheet-like overlay
    /// with the URL field. No detached NSPanel.
    static func showURLPanel() {
        NotificationCenter.default.post(name: .requestOpenURL, object: nil)
    }
}

// MARK: - PlayerWindow (root)
//
// All player state reads are isolated to ControlBar so SwiftUI only
// re-evaluates the bar, never PlayerWindow.body or PlayerNativeView.
struct PlayerWindow: View {
    @State private var player: Player?
    @State private var mediaLoaded = false
    @State private var showURLOverlay = false
    @State private var isFullscreen = false
    @State private var controlsVisibleInFS = false
    @State private var hideTask: Task<Void, Never>?

    private var showsBottomBar: Bool {
        !isFullscreen || controlsVisibleInFS
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if mediaLoaded, let player {
                PlayerNativeView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showsBottomBar {
                BottomBar(player: player)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if showURLOverlay {
                URLOverlay(
                    onSubmit: { url in
                        showURLOverlay = false
                        Task { await play(url: url) }
                    },
                    onCancel: { showURLOverlay = false }
                )
                .transition(.opacity)
            }
        }
        .overlay {
            if let player, let err = player.state.error, !err.isEmpty {
                ErrorOverlay(message: err, onDismiss: {
                    player.clearError()
                })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showURLOverlay)
        .animation(.easeInOut(duration: 0.2), value: showsBottomBar)
        .task { await boot() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
            syncFullscreenState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            syncFullscreenState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            syncFullscreenState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openURLSubmitted)) { note in
            if let url = note.object as? URL { Task { await play(url: url) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenURL)) { _ in
            showURLOverlay = true
        }
        .onContinuousHover { phase in
            guard isFullscreen else { return }
            switch phase {
            case .active:
                if !controlsVisibleInFS { controlsVisibleInFS = true }
                hideTask?.cancel()
                hideTask = Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisibleInFS = false
                    }
                }
            case .ended:
                hideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    controlsVisibleInFS = false
                }
            }
        }
        .background(hiddenShortcutButtons)
    }

    private func syncFullscreenState() {
        let fs = (NSApp.mainWindow ?? NSApp.keyWindow)?.styleMask.contains(.fullScreen) ?? false
        if isFullscreen != fs {
            isFullscreen = fs
            controlsVisibleInFS = false
            hideTask?.cancel()
        }
    }

    @ViewBuilder
    private var hiddenShortcutButtons: some View {
        Button("Open File", action: { AppActions.pickFile() })
            .keyboardShortcut("o", modifiers: .command).hidden()
        Button("Open URL", action: { AppActions.showURLPanel() })
            .keyboardShortcut("u", modifiers: .command).hidden()
    }

    @MainActor
    private func boot() async {
        do {
            let backend = try NativeBackend()
            player = Player(backend: backend)
        } catch {}
    }

    @MainActor
    private func play(url: URL) async {
        guard let player else { return }
        mediaLoaded = true
        player.play(url: url)
    }
}

// MARK: - Empty state (no media loaded)
//
// Just a neutral background. The open buttons live in the bottom bar.

private struct EmptyStateView: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}

// MARK: - Bottom bar
//
// Unified bar at the bottom of the window. Always shows the full transport
// controls layout — when no media is loaded the playback controls disable
// but the file/URL/fullscreen entry points stay live, so there's no layout
// shift when media loads. All player-state reads are confined here so
// PlayerWindow.body stays stable.

private struct BottomBar: View {
    let player: Player?

    static let height: CGFloat = 56

    // Transport state (only relevant during playback)
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var seekHoldUntil: Date = .distantPast

    var body: some View {
        HStack(spacing: 0) {
            transportControls(player: player)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Transport controls
    //
    // Always shown, including in the empty state. When `player` is nil (no
    // media loaded), every playback control is disabled but the layout stays
    // intact so the bar doesn't shift when media loads. The file/URL/
    // fullscreen buttons stay enabled in the empty state — they are the
    // entry points.

    private func transportControls(player: Player?) -> some View {
        let hasMedia = player != nil
        return HStack(spacing: 12) {
            // Play / pause
            Button(action: {
                guard let player else { return }
                if player.state.isPlaying { player.pause() } else { player.resume() }
            }) {
                Image(systemName: (player?.state.isPlaying ?? false) ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!hasMedia)

            // Skip back 10s
            Button(action: {
                guard let player else { return }
                player.seek(to: .seconds(max(0, position(player) - 10)))
            }) {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .disabled(!hasMedia)

            // Skip forward 10s
            Button(action: {
                guard let player else { return }
                player.seek(to: .seconds(min(duration(player), position(player) + 10)))
            }) {
                Image(systemName: "goforward.10")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .disabled(!hasMedia)

            // Time label + seek slider
            Text(format(seconds: position(player)))
                .monospacedDigit()
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(value: seekBinding(player: player),
                   in: 0...max(0.001, duration(player)),
                   onEditingChanged: { editing in
                       isDragging = editing
                       if !editing, let player {
                           seekHoldUntil = Date().addingTimeInterval(0.4)
                           player.seek(to: .seconds(dragValue))
                       }
                   })
                   .tint(.accentColor)
                   .disabled(!hasMedia)

            Text(format(seconds: duration(player)))
                .monospacedDigit()
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            // Volume
            Button(action: {
                guard let player else { return }
                player.setVolume(player.state.volume > 0.001 ? 0 : 1)
            }) {
                Image(systemName: (player?.state.volume ?? 0) <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(!hasMedia)

            Slider(value: volumeBinding(player: player), in: 0...1)
                .tint(.accentColor)
                .frame(width: 64)
                .disabled(!hasMedia)

            // Status / info
            if let info = statusText(player: player) {
                Text(info)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Actions
            Button(action: { AppActions.pickFile() }) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open file (⌘O)")

            Button(action: { AppActions.showURLPanel() }) {
                Image(systemName: "link")
            }
            .buttonStyle(.borderless)
            .help("Open URL (⌘U)")

            Button(action: {
                let target = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
                target?.toggleFullScreen(nil)
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Toggle fullscreen")
        }
        .padding(.horizontal, 14)
        .font(.system(size: 12))
        .labelStyle(.iconOnly)
    }

    // MARK: - Helpers

    private func position(_ p: Player?) -> Double {
        guard let p else { return 0 }
        if isDragging { return dragValue }
        if Date() < seekHoldUntil { return dragValue }
        return p.state.position.toDoubleSeconds
    }

    private func duration(_ p: Player?) -> Double {
        p?.state.duration.toDoubleSeconds ?? 0
    }

    private func seekBinding(player: Player?) -> Binding<Double> {
        Binding(get: { position(player) }, set: { dragValue = $0 })
    }

    private func volumeBinding(player: Player?) -> Binding<Double> {
        Binding(get: { player?.state.volume ?? 0 }, set: { v in player?.setVolume(v) })
    }

    private func statusText(player: Player?) -> String? {
        guard let s = player?.state else { return nil }
        if s.isBuffering { return "buffering…" }
        if let v = s.videoInfo { return "\(v.width)×\(v.height)" }
        if s.duration > .zero, !s.isPlaying { return "paused" }
        return nil
    }

    private func format(seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - URL overlay (inline modal)
//
// Centered, dimmed backdrop, single TextField + Open/Cancel. Replaces the
// detached NSPanel — stays in the main window so it doesn't get lost behind
// other windows or feel like a separate utility.

private struct URLOverlay: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    let onSubmit: (URL) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)

            VStack(spacing: 12) {
                Text("Open URL")
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("https://…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(submit)
                }
                .frame(width: 320)

                HStack(spacing: 8) {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Open", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed) { onSubmit(url) }
    }
}

// MARK: - Error overlay
//
// Centered modal showing the full player error string with a Copy + Dismiss
// button. Replaces the old status-text-only "error" hint, which hid the
// actual message — making decode failures (e.g. HDR/Dolby Vision streams
// unsupported by the open codec) look like a silent freeze.

private struct ErrorOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Playback Error")
                        .font(.headline)
                }

                ScrollView {
                    Text(message)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)

                HStack(spacing: 8) {
                    Button(action: copy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
}

extension Notification.Name {
    static let openURLSubmitted = Notification.Name("io.reflux.PlayerKit.openURLSubmitted")
    static let requestOpenURL = Notification.Name("io.reflux.PlayerKit.requestOpenURL")
}
