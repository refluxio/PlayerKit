import Foundation

/// Main playback control protocol. All UI-facing playback goes through this.
@MainActor
public protocol Playable: AnyObject {
    /// Current playback state. UI binds to this.
    var state: PlayerState { get }

    /// Called when state changes. UI subscribes here instead of polling.
    var onStateChange: ((PlayerState) -> Void)? { get set }

    /// Start or restart playback at the given URL.
    /// - Parameters:
    ///   - url: Media URL (local file, HTTP, or custom scheme).
    ///   - headers: HTTP headers sent with the request.
    ///   - seekTo: Optional start position.
    ///   - knownDuration: Pre-known duration, skips probe if non-nil.
    func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration?)

    /// Pause playback. Call `resume()` to continue.
    func pause()

    /// Resume from paused state.
    func resume()

    /// Seek to a specific position.
    func seek(to: Duration)

    /// Stop playback and release resources.
    func stop()

    /// Set volume (0.0 = silent, 1.0 = unity).
    func setVolume(_ volume: Double)

    /// Set playback rate (1.0 = normal, 2.0 = double speed).
    func setRate(_ rate: Double)

    /// Select an audio track by its identifier.
    func selectAudioTrack(id: String)

    /// Select a subtitle track, or pass nil to disable subtitles.
    func selectSubtitle(id: String?)
}

extension Playable {
    /// Manually trigger an onStateChange notification with the current state.
    public func notifyStateChange() {
        onStateChange?(state)
    }
}
