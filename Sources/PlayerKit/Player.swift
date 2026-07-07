import Foundation
import QuartzCore

@Observable
@MainActor
public final class Player {

    public var state = PlayerState()

    private let backend: any Playable

    public init(backend: any Playable) {
        self.backend = backend
        backend.onStateChange = { [weak self] s in self?.state = s }
    }

    // MARK: - Playable forwarding

    public func play(url: URL, headers: [String: String] = [:],
                     seekTo: Duration? = nil, knownDuration: Duration? = nil) {
        backend.play(url: url, headers: headers, seekTo: seekTo, knownDuration: knownDuration)
    }
    public func pause()                        { backend.pause() }
    public func resume()                       { backend.resume() }
    public func seek(to: Duration)             { backend.seek(to: to) }
    public func stop()                         { backend.stop() }
    public func setVolume(_ v: Double)         { backend.setVolume(v) }
    public func setRate(_ r: Double)           { backend.setRate(r) }
    public func selectAudioTrack(id: String)   { backend.selectAudioTrack(id: id) }
    public func selectSubtitle(id: String?)    { backend.selectSubtitle(id: id) }

    // MARK: - Renderer (requires PlayerBackend)

    public var renderLayer: CALayer? {
        (backend as? any PlayerBackend)?.renderer.layer
    }

    // MARK: - Frame sinks (requires PlayerBackend)

    public func addFrameSink(_ sink: any FrameSink) {
        (backend as? any PlayerBackend)?.addFrameSink(sink)
    }

    public func removeFrameSink(_ sink: any FrameSink) {
        (backend as? any PlayerBackend)?.removeFrameSink(sink)
    }

    // MARK: - Lifecycle

    public func prepareForReuse() {
        (backend as? any PlayerBackend)?.prepareForReuse()
    }
}
