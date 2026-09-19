import AVFoundation
import Foundation

/// Audio output backend. Implementations handle PCM rendering or compressed passthrough.
public protocol AudioOutputBackend: AnyObject {
    /// Whether this backend supports compressed audio passthrough (AC3/DTS/Atmos).
    var supportsPassthrough: Bool { get }
    /// Buffered audio duration in seconds.
    var bufferedDuration: Double { get }

    /// Configure the output for a given stream.
    func configure(streamInfo: AudioStreamInfo) async throws

    /// Output a decoded PCM buffer. Implemented by the open-source AudioUnitOutput.
    func outputPCM(_ buffer: AVAudioPCMBuffer, pts: Double)

    /// Output a compressed audio packet. PRO PassthroughOutput implements this.
    /// The open-source AudioUnitOutput treats this as a no-op.
    func outputCompressed(_ packet: Data, pts: Double, codec: String)

    /// Current media playback position in seconds, if this backend maintains a
    /// real playback clock (e.g. an AVSampleBufferRenderSynchronizer timebase).
    ///
    /// Non-nil providers become the master A/V sync clock in NativeBackend's
    /// display loop. This matters for passthrough mode: there the PCM
    /// AudioClock never runs (audio is not decoded), and without a real
    /// reference the display loop free-wheels at decode speed — MKV/DTS
    /// sources played at ~2-3x. Nil (the default) leaves pacing on AudioClock.
    var playbackTime: Double? { get }

    func flush()
    func pause()
    func resume()
}

public extension AudioOutputBackend {
    /// Default: no playback clock — NativeBackend falls back to its AudioClock.
    var playbackTime: Double? { nil }
}
