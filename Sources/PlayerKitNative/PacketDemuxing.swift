import Foundation
import CFFmpeg

/// The demux-surface `NativeBackend`'s demux loop and stream-metadata reads
/// need. Implemented by `FFmpegDemuxer` (single file / concat list) and
/// `MultiClipDemuxer` (multi-clip disc playback, delegating to whichever
/// clip's `FFmpegDemuxer` is currently active).
///
/// Member set is exactly NativeBackend's access surface on
/// `self.demuxer` — the protocol exists so the backend can hold either
/// implementation behind one existential without knowing which one it has.
///
/// NOT @MainActor-isolated: the demux loop calls `readPacket()`/`seek()` on
/// a background GCD thread. Both conformers are `@unchecked Sendable` (all
/// mutable state is guarded by the demux lock / confined to the read thread),
/// which is why the protocol carries `Sendable` so the existential stays
/// usable across the queue hop.
protocol PacketDemuxing: AnyObject, Sendable {
    var formatContext: UnsafeMutablePointer<AVFormatContext>? { get }
    var videoStream: UnsafeMutablePointer<AVStream>? { get }
    var audioStream: UnsafeMutablePointer<AVStream>? { get }
    var subtitleStream: UnsafeMutablePointer<AVStream>? { get }
    var videoStreamIndex: Int32 { get }
    var audioStreamIndex: Int32 { get }
    var subtitleStreamIndex: Int32 { get }
    var downloadedUpToOffset: Int64 { get }
    var totalFileBytes: Int64 { get }
    var isPassthroughCodec: Bool { get }
    var isDolbyVision: Bool { get }
    var doviProfile: UInt8 { get }
    var doviBLSignalCompatibilityId: UInt8 { get }
    var hasHDR10Plus: Bool { get }
    var audioIsAtmos: Bool { get }
    var sampleAspectRatio: Double { get }
    func selectAudioStream(by id: Int) -> Bool
    func selectSubtitleStream(by id: Int?)
    func readPacket() -> (streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>, didSwitchClip: Bool)?
    func seek(to time: Double) -> Bool
    func close()
}

extension FFmpegDemuxer: PacketDemuxing {}
