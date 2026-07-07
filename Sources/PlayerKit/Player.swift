import Foundation
import QuartzCore

/// High-level player facade. Wraps a backend and exposes its state via @Observable.
@Observable
@MainActor
public final class Player {

    /// Current playback state. UI binds to this observable property.
    public var state = PlayerState()

    private let backend: any Playable

    /// Create a player with the given backend.
    /// - Parameter backend: A Playable-compliant backend (NativeBackend or MPVBackend).
    public init(backend: any Playable) {
        self.backend = backend
        backend.onStateChange = { [weak self] s in self?.state = s }
    }

    // MARK: - Playable forwarding

    /// Start or restart playback at the given URL.
    /// - Parameters:
    ///   - url: Media URL (local file, HTTP, or custom scheme).
    ///   - headers: HTTP headers sent with the request.
    ///   - seekTo: Optional start position.
    ///   - knownDuration: Pre-known duration, skips probe if non-nil.
    public func play(url: URL, headers: [String: String] = [:],
                     seekTo: Duration? = nil, knownDuration: Duration? = nil) {
        backend.play(url: url, headers: headers, seekTo: seekTo, knownDuration: knownDuration)
    }

    /// Pause playback. Call `resume()` to continue.
    public func pause()                        { backend.pause() }

    /// Resume from paused state.
    public func resume()                       { backend.resume() }

    /// Seek to a specific position.
    public func seek(to: Duration)             { backend.seek(to: to) }

    /// Stop playback and release resources.
    public func stop()                         { backend.stop() }

    /// Set volume (0.0 = silent, 1.0 = unity).
    public func setVolume(_ v: Double)         { backend.setVolume(v) }

    /// Set playback rate (1.0 = normal, 2.0 = double speed).
    public func setRate(_ r: Double)           { backend.setRate(r) }

    /// Select an audio track by its identifier.
    public func selectAudioTrack(id: String)   { backend.selectAudioTrack(id: id) }

    /// Select a subtitle track, or pass nil to disable subtitles.
    public func selectSubtitle(id: String?)    { backend.selectSubtitle(id: id) }

    // MARK: - Renderer (requires PlayerBackend)

    /// The renderer's Core Animation layer for embedding in a view hierarchy.
    /// Requires a PlayerBackend-compliant backend; nil otherwise.
    public var renderLayer: CALayer? {
        (backend as? any PlayerBackend)?.renderer.layer
    }

    // MARK: - Frame sinks (requires PlayerBackend)

    /// Register a frame sink to receive decoded video frames.
    public func addFrameSink(_ sink: any FrameSink) {
        (backend as? any PlayerBackend)?.addFrameSink(sink)
    }

    /// Remove a previously registered frame sink.
    public func removeFrameSink(_ sink: any FrameSink) {
        (backend as? any PlayerBackend)?.removeFrameSink(sink)
    }

    // MARK: - Lifecycle

    /// Reset the player for reuse with new media.
    public func prepareForReuse() {
        (backend as? any PlayerBackend)?.prepareForReuse()
    }
}
