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

    func flush()
    func pause()
    func resume()
}
