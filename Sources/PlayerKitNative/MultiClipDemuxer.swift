import Foundation
import CFFmpeg
import PlayerKit
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "multiclip")

/// Plays an ordered sequence of independently-timed clip readers as one
/// continuous presentation timeline. Each clip is demuxed with its own
/// FFmpegDemuxer/AVFormatContext (clips don't share a PTS/PCR base); every
/// packet's pts/dts gets the accumulated duration of preceding clips added
/// before the caller sees it, so downstream code sees one monotonically
/// increasing timeline — equivalent to what ffmpeg's own concat demuxer
/// does for URL-addressable inputs, reimplemented here because these
/// readers are not protocol-openable by ffmpeg. See
/// docs/superpowers/specs/2026-08-22-disc-multiclip-pts-continuity-design.md
/// (reflux repo) for the full rationale.
final class MultiClipDemuxer: @unchecked Sendable {
    private let readers: [any MediaRandomAccessReader]
    let timeline: ClipTimeline
    private var currentIndex: Int = -1
    private var current: FFmpegDemuxer?
    private var pendingSwitchFlag = false

    /// A fully-opened demuxer for the next sequential clip, produced in the
    /// background by `preOpenQueue` while the current clip is still playing.
    /// Consumed by `switchTo` at the EOF seam so the 1~1.5s
    /// avformat_open_input + probe cost is paid ahead of time instead of at
    /// the seam. Written on `preOpenQueue`, read/written on the reading
    /// thread; a stale or not-yet-ready hint is harmless — `switchTo` falls
    /// back to a synchronous open, so correctness never depends on this
    /// being populated. Internal (not private) so tests can observe that the
    /// background open landed and that the seam switch reuses this instance.
    var preOpenedNext: (index: Int, demuxer: FFmpegDemuxer)?
    /// True while a pre-open task is running. The 3s lead window covers many
    /// packets, so without this guard every packet near the end of a clip
    /// would spawn its own concurrent open of the same next reader.
    private var preOpenInFlight = false
    private let preOpenQueue = DispatchQueue(label: "io.reflux.PlayerKit.multiclip.preopen", qos: .userInitiated)
    /// Remaining clip time below this threshold starts the background
    /// pre-open of the next clip. ffmpeg avformat_open_input + probe
    /// measures ~1–1.5s in practice; 3s leaves margin.
    private static let preOpenLeadSecs: Double = 3.0

    init?(clips: [(reader: any MediaRandomAccessReader, durationSecs: Double)]) {
        guard let timeline = ClipTimeline(durationsSecs: clips.map(\.durationSecs)) else { return nil }
        self.readers = clips.map(\.reader)
        self.timeline = timeline
    }

    /// Opens clip 0. Must be called before readPacket()/seek().
    func open() throws {
        try switchTo(clipIndex: 0, localSeekSecs: nil)
    }

    /// Current clip's own demuxer — caller reads stream metadata (codec
    /// params, HDR flags, sample aspect ratio, etc.) off this for whichever
    /// clip is currently active.
    var currentDemuxer: FFmpegDemuxer? { current }

    private func switchTo(clipIndex: Int, localSeekSecs: Double?) throws {
        current?.close()
        let pre = preOpenedNext
        preOpenedNext = nil
        var reusedPreOpened = false
        if let pre, pre.index == clipIndex, localSeekSecs == nil {
            // EOF seam — the next clip was already opened in the background;
            // hand it over without paying the open cost again. Only valid
            // when not seeking: a seek target clip isn't necessarily the
            // sequential next one, so the cache can't be trusted there.
            current = pre.demuxer
            reusedPreOpened = true
        } else {
            // Cache miss (seek target differs from the sequential next clip,
            // or the background open hadn't landed yet) — discard the stale
            // entry and open synchronously. This is the correctness fallback.
            if let pre { pre.demuxer.close() }
            let demuxer = FFmpegDemuxer()
            try demuxer.open(reader: readers[clipIndex],
                             knownDurationSecs: timeline.durationsSecs[clipIndex])
            if let localSeekSecs, localSeekSecs > 0 {
                _ = demuxer.seek(to: localSeekSecs)
            }
            current = demuxer
        }
        currentIndex = clipIndex
        pendingSwitchFlag = true
        logger.info("switched to clip \(clipIndex) offset=\(String(format: "%.3f", self.timeline.startOffsets[clipIndex]))s\(reusedPreOpened ? " (pre-opened)" : "")")
    }

    func readPacket() -> (streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>, didSwitchClip: Bool)? {
        guard let current else { return nil }
        if let result = current.readPacket() {
            let offsetSecs = timeline.startOffsets[currentIndex]
            // Local PTS (in this clip's own time domain) is computed for
            // every packet regardless of offset — it drives the pre-open
            // trigger. The rebase still only applies when an offset exists.
            var localPtsSecs: Double? = nil
            if let stream = streamFor(result.streamIndex) {
                let tb = stream.pointee.time_base
                let nopts = Int64(bitPattern: 0x8000000000000000)
                if result.packet.pointee.pts != nopts, tb.den > 0 {
                    localPtsSecs = Double(result.packet.pointee.pts) * Double(tb.num) / Double(tb.den)
                }
                if offsetSecs != 0 {
                    rebase(&result.packet.pointee.pts, offsetSecs: offsetSecs, timeBase: tb)
                    rebase(&result.packet.pointee.dts, offsetSecs: offsetSecs, timeBase: tb)
                }
            }
            if let localPtsSecs { maybeTriggerPreOpen(currentPacketPtsSecs: localPtsSecs) }
            let switched = pendingSwitchFlag
            pendingSwitchFlag = false
            return (result.streamIndex, result.packet, switched)
        }
        // Current clip exhausted (EOF) — advance to the next one, if any.
        guard currentIndex + 1 < readers.count else { return nil }
        do {
            try switchTo(clipIndex: currentIndex + 1, localSeekSecs: nil)
        } catch {
            return nil
        }
        return readPacket()
    }

    /// Fires a background pre-open of the next sequential clip once the
    /// current one has less than `preOpenLeadSecs` left. Idempotent: does
    /// nothing when a pre-open is already in flight or the cache already
    /// covers the next clip.
    private func maybeTriggerPreOpen(currentPacketPtsSecs: Double) {
        guard currentIndex + 1 < readers.count else { return }
        // A cached entry for the actual next clip already covers the seam.
        // A stale entry (pre-open landed after we already switched away from
        // the clip it was for) must NOT block a fresh pre-open for the real
        // next clip. Also skip while a pre-open is still in flight — its
        // completion lands shortly and the next packet re-evaluates.
        if preOpenedNext?.index == currentIndex + 1 || preOpenInFlight { return }
        let clipEndSecs = timeline.durationsSecs[currentIndex]
        guard clipEndSecs - currentPacketPtsSecs <= Self.preOpenLeadSecs else { return }
        let nextIndex = currentIndex + 1
        let nextReader = readers[nextIndex]
        let nextDuration = timeline.durationsSecs[nextIndex]
        preOpenInFlight = true
        preOpenQueue.async { [weak self] in
            let demuxer = FFmpegDemuxer()
            let opened = (try? demuxer.open(reader: nextReader, knownDurationSecs: nextDuration)) != nil
            if opened {
                self?.preOpenedNext = (nextIndex, demuxer)
            }
            // Cleared on both success and failure so a failed pre-open can
            // be retried by the next packet, not suppressed forever.
            self?.preOpenInFlight = false
        }
    }

    func seek(to time: Double) -> Bool {
        let (targetIndex, localSecs) = timeline.locate(globalSecs: time)
        do {
            try switchTo(clipIndex: targetIndex, localSeekSecs: localSecs)
        } catch {
            return false
        }
        return true
    }

    func close() {
        current?.close()
        current = nil
        preOpenedNext?.demuxer.close()
        preOpenedNext = nil
    }

    private func streamFor(_ streamIndex: Int32) -> UnsafeMutablePointer<AVStream>? {
        guard let ctx = current?.formatContext, streamIndex >= 0,
              streamIndex < Int32(ctx.pointee.nb_streams) else { return nil }
        return ctx.pointee.streams[Int(streamIndex)]
    }

    private func rebase(_ ts: inout Int64, offsetSecs: Double, timeBase: AVRational) {
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard ts != nopts, timeBase.den > 0 else { return }
        let offsetInTimeBase = Int64((offsetSecs * Double(timeBase.den) / Double(timeBase.num)).rounded())
        ts += offsetInTimeBase
    }
}

// MARK: - PacketDemuxing

extension MultiClipDemuxer: PacketDemuxing {
    // Stream metadata is read off whichever clip's demuxer is currently
    // active — NativeBackend's _finishOpen configures decoders from this,
    // and only the active clip's stream layout is meaningful at any moment.
    // Fallback defaults mirror FFmpegDemuxer's own "no active stream" values
    // so callers that read these before/without a successful open() (nil
    // currentDemuxer) behave identically to a failed single-file open.
    var formatContext: UnsafeMutablePointer<AVFormatContext>? { currentDemuxer?.formatContext }
    var videoStream: UnsafeMutablePointer<AVStream>? { currentDemuxer?.videoStream }
    var audioStream: UnsafeMutablePointer<AVStream>? { currentDemuxer?.audioStream }
    var subtitleStream: UnsafeMutablePointer<AVStream>? { currentDemuxer?.subtitleStream }
    var videoStreamIndex: Int32 { currentDemuxer?.videoStreamIndex ?? -1 }
    var audioStreamIndex: Int32 { currentDemuxer?.audioStreamIndex ?? -1 }
    var subtitleStreamIndex: Int32 { currentDemuxer?.subtitleStreamIndex ?? -1 }
    var downloadedUpToOffset: Int64 { currentDemuxer?.downloadedUpToOffset ?? -1 }
    var totalFileBytes: Int64 { currentDemuxer?.totalFileBytes ?? -1 }
    var isPassthroughCodec: Bool { currentDemuxer?.isPassthroughCodec ?? false }
    var isDolbyVision: Bool { currentDemuxer?.isDolbyVision ?? false }
    var doviProfile: UInt8 { currentDemuxer?.doviProfile ?? 0 }
    var doviBLSignalCompatibilityId: UInt8 { currentDemuxer?.doviBLSignalCompatibilityId ?? 0 }
    var hasHDR10Plus: Bool { currentDemuxer?.hasHDR10Plus ?? false }
    var audioIsAtmos: Bool { currentDemuxer?.audioIsAtmos ?? false }
    var sampleAspectRatio: Double { currentDemuxer?.sampleAspectRatio ?? 1.0 }
    func selectAudioStream(by id: Int) -> Bool { currentDemuxer?.selectAudioStream(by: id) ?? false }
    func selectSubtitleStream(by id: Int?) { currentDemuxer?.selectSubtitleStream(by: id) }
    // readPacket()/seek(to:)/close() already have class-level implementations
    // with the same signatures — no delegation needed here.
}
