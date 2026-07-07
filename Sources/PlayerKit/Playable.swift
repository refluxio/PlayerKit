import Foundation

@MainActor
public protocol Playable: AnyObject {
    var state: PlayerState { get }
    var onStateChange: ((PlayerState) -> Void)? { get set }

    func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration?)
    func pause()
    func resume()
    func seek(to: Duration)
    func stop()
    func setVolume(_ volume: Double)
    func setRate(_ rate: Double)
    func selectAudioTrack(id: String)
    func selectSubtitle(id: String?)
}

extension Playable {
    public func notifyStateChange() {
        onStateChange?(state)
    }
}
