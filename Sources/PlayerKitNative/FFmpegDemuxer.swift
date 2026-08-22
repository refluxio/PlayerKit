import Foundation
import CoreMedia
import CFFmpeg
import PlayerKit
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "demuxer")

/// FFmpeg's default av_log callback fprintf()s every message straight to
/// stderr. Some codecs log the exact same warning once per packet — e.g.
/// the native dca decoder on a lossless DTS-HD MA track logs "Residual
/// encoded channels are present without core" on *every* audio frame. Over
/// a feature-length BD remux that's tens of thousands of synchronous stderr
/// writes; under Xcode's debug console pipe each write is slow enough that
/// decode throughput drops well below real-time (observed: single-digit
/// fps, multi-second hangs, and visibly corrupted frames from the decode
/// pipeline falling behind), even though the messages themselves are
/// harmless.
///
/// AV_LOG_SKIP_REPEATED alone does NOT fix this: it only fully silences a
/// repeated line when FFmpeg's internal isatty() check on stderr is false.
/// Under lldb the device's stdio is backed by a pty, so isatty() reports
/// true and it still fprintf()s a shortened "Last message repeated N
/// times\r" on *every* occurrence — same call frequency as before, just a
/// shorter string (confirmed by device log: thousands of these lines at
/// the same rate as the original spam).
///
/// Cutting the level to AV_LOG_ERROR did not help either — on-device
/// testing showed the exact same per-frame spam still coming through,
/// which means dca's "Residual encoded channels" message is itself logged
/// at AV_LOG_ERROR (av_log's filter is "message level <= threshold", so
/// ERROR(16) <= ERROR(16) still passes). Rather than keep guessing at the
/// exact level a given codec uses for a given message, go straight to
/// AV_LOG_QUIET: nothing above PANIC gets through, so the level check
/// short-circuits every call unconditionally.
private let configureFFmpegLoggingOnce: Void = {
    av_log_set_level(AV_LOG_QUIET)
    av_log_set_flags(AV_LOG_SKIP_REPEATED)
}()

enum DemuxerError: Error, CustomStringConvertible {
    /// avformat_open_input returned non-zero. Carries the FFmpeg error code.
    case openFailed(Int32)
    /// avformat_find_stream_info returned < 0.
    case noStreams(Int32)
    /// No usable video or audio stream found after probing.
    case noUsableStreams

    var description: String {
        switch self {
        case .openFailed(let ret):
            // av_err2str returns a thread-local C string; copy it into Swift.
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(AV_ERROR_MAX_STRING_SIZE))
            defer { buf.deallocate() }
            _ = av_make_error_string(buf, Int(AV_ERROR_MAX_STRING_SIZE), ret)
            let msg = String(cString: buf)
            return "demux open failed (ret=\(ret)): \(msg)"
        case .noStreams(let ret):
            return "demux find_stream_info failed (ret=\(ret))"
        case .noUsableStreams:
            return "no usable video/audio stream found in container"
        }
    }
}

final class FFmpegDemuxer: @unchecked Sendable {
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    var formatContext: UnsafeMutablePointer<AVFormatContext>? { formatCtx }
    private var avioBridge: AVIOBridge?
    private(set) var duration: Double = 0

    var videoStreamIndex: Int32 { videoStream.map { $0.pointee.index } ?? -1 }
    var audioStreamIndex: Int32 { audioStream.map { $0.pointee.index } ?? -1 }
    /// Highest byte offset available in the reader's buffer. -1 if unknown (URL-based stream).
    var downloadedUpToOffset: Int64 { avioBridge?.downloadedUpToOffset ?? -1 }
    /// Total file size in bytes. -1 if unknown.
    var totalFileBytes: Int64 { avioBridge?.totalBytes ?? -1 }

    /// Returns true if the current audio stream carries a passthrough-capable codec
    /// (AC3, E-AC3, DTS, TrueHD).
    var isPassthroughCodec: Bool {
        guard let audioStream else { return false }
        let codecId = audioStream.pointee.codecpar.pointee.codec_id
        switch codecId {
        case AV_CODEC_ID_AC3,
             AV_CODEC_ID_EAC3,
             AV_CODEC_ID_DTS,
             AV_CODEC_ID_TRUEHD:
            return true
        default:
            return false
        }
    }

    /// True when the video stream has a Dolby Vision configuration record
    /// (AV_PKT_DATA_DOVI_CONF) in its codec parameters side data.
    var isDolbyVision: Bool {
        guard let vs = videoStream else { return false }
        let par = vs.pointee.codecpar.pointee
        guard par.nb_coded_side_data > 0, let sideData = par.coded_side_data else {
            return false
        }
        for i in 0..<Int(par.nb_coded_side_data) {
            if sideData[i].type == AV_PKT_DATA_DOVI_CONF { return true }
        }
        return false
    }

    /// Parsed Dolby Vision configuration record (profile + signal compatibility id).
    /// Returns nil for non-DV streams, or when the side data payload is too short
    /// to contain a valid `AVDOVIDecoderConfigurationRecord` (needs ≥9 bytes).
    var doviConfiguration: AVDOVIDecoderConfigurationRecord? {
        guard let vs = videoStream else { return nil }
        let par = vs.pointee.codecpar.pointee
        guard par.nb_coded_side_data > 0, let sideData = par.coded_side_data else {
            return nil
        }
        for i in 0..<Int(par.nb_coded_side_data) {
            let sd = sideData[i]
            guard sd.type == AV_PKT_DATA_DOVI_CONF else { continue }
            // The payload is a fixed-layout 9-byte record; verify size before
            // binding the pointer (avformat may attach shorter payloads from
            // malformed streams).
            guard Int(sd.size) >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size,
                  let raw = sd.data else { return nil }
            return raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { $0.pointee }
        }
        return nil
    }

    /// DV profile (4/5/7/8). 0 when the stream is not Dolby Vision.
    var doviProfile: UInt8 { doviConfiguration?.dv_profile ?? 0 }

    /// BL signal compatibility id from the DV config record. 0 for non-DV
    /// streams; 2 = HDR10-compatible CT mode (can fall back to HDR10 rendering).
    var doviBLSignalCompatibilityId: UInt8 {
        doviConfiguration?.dv_bl_signal_compatibility_id ?? 0
    }

    /// True when the video stream carries HDR10+ ST 2094-40 dynamic metadata
    /// (AV_PKT_DATA_DYNAMIC_HDR10_PLUS) in its codec parameters side data.
    var hasHDR10Plus: Bool {
        guard let vs = videoStream else { return false }
        let par = vs.pointee.codecpar.pointee
        guard par.nb_coded_side_data > 0, let sideData = par.coded_side_data else {
            return false
        }
        for i in 0..<Int(par.nb_coded_side_data) {
            if sideData[i].type == AV_PKT_DATA_DYNAMIC_HDR10_PLUS { return true }
        }
        return false
    }

    /// True when the active audio stream carries Dolby Atmos metadata.
    /// - TrueHD: profile == AV_PROFILE_TRUEHD_ATMOS (30)
    /// - E-AC3: stream title contains "atmos" (case-insensitive) or channel count > 8
    var audioIsAtmos: Bool {
        guard let as_ = audioStream else { return false }
        let par = as_.pointee.codecpar.pointee
        let codecId = par.codec_id

        if codecId == AV_CODEC_ID_TRUEHD {
            return Int32(par.profile) == AV_PROFILE_TRUEHD_ATMOS
        }

        if codecId == AV_CODEC_ID_EAC3 {
            if let meta = as_.pointee.metadata {
                let titleEntry = av_dict_get(meta, "title", nil, 0)
                if let titleEntry, let titleVal = titleEntry.pointee.value {
                    let title = String(cString: titleVal).lowercased()
                    if title.contains("atmos") { return true }
                }
            }
            return par.ch_layout.nb_channels > 8
        }

        return false
    }

    private(set) var videoStream: UnsafeMutablePointer<AVStream>?
    private(set) var audioStream: UnsafeMutablePointer<AVStream>?
    private var audioStreamScore: Int = 0
    private(set) var subtitleStream: UnsafeMutablePointer<AVStream>?

    var subtitleStreamIndex: Int32 { subtitleStream.map { $0.pointee.index } ?? -1 }

    /// Select (or deselect) the active subtitle stream by stream index.
    /// Pass nil to disable subtitle decoding.
    func selectSubtitleStream(by id: Int?) {
        defer { applyStreamDiscard() }
        guard let id else { subtitleStream = nil; return }
        guard let ctx = formatCtx else { return }
        let nb = Int(ctx.pointee.nb_streams)
        for i in 0..<nb {
            guard let s = ctx.pointee.streams[i] else { continue }
            guard s.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            if Int(s.pointee.index) == id { subtitleStream = s; return }
        }
    }

    /// Switch the active audio stream by stream index. Returns true on success.
    func selectAudioStream(by id: Int) -> Bool {
        defer { applyStreamDiscard() }
        guard let ctx = formatCtx else { return false }
        let nb = Int(ctx.pointee.nb_streams)
        for i in 0..<nb {
            guard let s = ctx.pointee.streams[i] else { continue }
            guard s.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            if Int(s.pointee.index) == id {
                audioStream = s
                audioStreamScore = 0  // reset score so it won't override manual selection
                return true
            }
        }
        return false
    }

    /// Tells the demuxer to skip PES reassembly/buffering entirely for every
    /// stream except the selected video/audio/subtitle ones. Without this,
    /// libavformat internally reassembles and tracks packets for *every* PID
    /// in the container — for a raw BDMV STREAM clip carrying a dozen-plus
    /// unused foreign-language audio tracks and PGS subtitle tracks alongside
    /// the one video/audio pair actually played, that internal bookkeeping
    /// alone was enough to make decode fall behind real-time (observed: ~0.2
    /// display fps, seconds-long stalls) even though our own packet-routing
    /// loop already ignored unselected streams' payloads. This mirrors how
    /// mpv/ffplay configure demuxers via `--vid`/`--aid`/`--sid` track
    /// selection — selecting a track sets discard on every other one, it
    /// doesn't just ignore their packets after the fact.
    private func applyStreamDiscard() {
        guard let ctx = formatCtx else { return }
        let nb = Int(ctx.pointee.nb_streams)
        let keep: Set<Int32> = Set([videoStream, audioStream, subtitleStream]
            .compactMap { $0?.pointee.index })
        for i in 0..<nb {
            guard let s = ctx.pointee.streams[i] else { continue }
            s.pointee.discard = keep.contains(s.pointee.index) ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Video stream's sample aspect ratio (SAR). Defaults to 1:1 if not set.
    /// Non-square pixels are common in H.264 SD content — e.g. 720×576 with
    /// SAR 16:15 gives a display aspect of 768×576 (4:3).
    var sampleAspectRatio: Double {
        guard let vs = videoStream else { return 1.0 }
        let sar = vs.pointee.sample_aspect_ratio
        guard sar.num > 0, sar.den > 0 else { return 1.0 }
        return Double(sar.num) / Double(sar.den)
    }

    func open(url: URL, headers: [String: String] = [:], skipDurationProbe: Bool = false,
              knownDurationSecs: Double? = nil) throws {
        _ = configureFFmpegLoggingOnce
        close()
        formatCtx = avformat_alloc_context()
        guard formatCtx != nil else { throw DemuxerError.openFailed(-1) }

        // Set probe options via AVDictionary (must be before avformat_open_input)
        // analyzeduration/probesize control how much data avformat_find_stream_info
        // reads to estimate framerate and refine codec parameters. Color metadata
        // (color_trc, color_space, bits_per_raw_sample, profile) comes from the
        // container header (CodecPrivate/SPS), not from probing packets — so
        // reducing these only affects framerate accuracy, not HDR detection.
        var opts: OpaquePointer?
        // Reduce probe size for faster startup. Color metadata (color_trc,
        // color_space, bits_per_raw_sample, profile) comes from the container
        // header (CodecPrivate/SPS), not from probing packets. 256KB is enough
        // to parse the first keyframe's SPS and estimate framerate.
        av_dict_set(&opts, "analyzeduration", "500000", 0)   // 0.5s
        av_dict_set(&opts, "probesize", "262144", 0)          // 256KB

        // HTTP protocol options for network streams.
        // seekable=1: force seekable connection so ffmpeg uses Range requests
        // to find moov atom at file end instead of downloading the entire file.
        // Without this, some CDN responses cause ffmpeg to fall back to linear
        // read, which for moov-at-end MP4s means downloading gigabytes before
        // the container can be parsed.
        if !url.isFileURL {
            av_dict_set(&opts, "seekable", "1", 0)
        }

        if !headers.isEmpty {
            let dict = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            av_dict_set(&opts, "headers", dict, 0)
        }

        // For local files, pass the plain filesystem path — FFmpeg's `file:`
        // protocol does not URL-decode (%20 → space), so `absoluteString` like
        // `file:///foo%20bar/baz.mp4` would fail with ENOENT (-2) for any path
        // containing spaces or other percent-encoded characters. Network URLs
        // (http/https/rtmp/...) must go through as absoluteString.
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            urlString = url.absoluteString
        }
        logger.info("opening url=\(urlString, privacy: .public)")

        var localCtx = formatCtx
        let ret = avformat_open_input(&localCtx, urlString, nil, &opts)
        // avformat_open_input takes ownership of freeing formatCtx on failure
        // and may set it to nil — write back so our state stays consistent.
        formatCtx = localCtx

        av_dict_free(&opts)

        guard ret == 0 else {
            logger.error("avformat_open_input FAILED, ret=\(ret) url=\(urlString, privacy: .public)")
            throw DemuxerError.openFailed(ret)
        }
        logger.info("avformat_open_input OK")

        try finishOpen(skipDurationProbe: skipDurationProbe, isNetwork: !url.isFileURL,
                       knownDurationSecs: knownDurationSecs)
    }

    /// Open a concat demuxer list file for BDMV disc clip playback.
    /// The list file contains lines like `file 'https://...'` for each clip.
    /// ffmpeg's concat demuxer virtually stitches the clips and supports
    /// precise time-based seek across clip boundaries.
    func openConcat(listFileURL: URL, headers: [String: String] = [:],
                    skipDurationProbe: Bool = false, knownDurationSecs: Double? = nil) throws {
        _ = configureFFmpegLoggingOnce
        close()
        formatCtx = avformat_alloc_context()
        guard formatCtx != nil else { throw DemuxerError.openFailed(-1) }

        var opts: OpaquePointer?
        av_dict_set(&opts, "analyzeduration", "500000", 0)
        av_dict_set(&opts, "probesize", "262144", 0)
        av_dict_set(&opts, "safe", "0", 0)  // allow arbitrary URLs in concat list

        // NOTE: `headers` here only applies to opening this local list file
        // (a no-op for `file:`), NOT to the per-clip http URLs the concat
        // demuxer opens internally — those get their own AVDictionary built
        // solely from that clip's `option` directives in the list file (see
        // NativeBackend.concatFileEntry, which writes `option user_agent` /
        // `option referer` / `option headers` per file for that purpose).
        if !headers.isEmpty {
            let dict = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            av_dict_set(&opts, "headers", dict, 0)
        }

        // Explicitly request the concat demuxer so ffmpeg doesn't auto-detect
        // the list file as a plain text file.
        let fmt = av_find_input_format("concat")
        let path = listFileURL.path

        logger.info("opening concat list=\(path, privacy: .public) clips headers=\(headers.count)")

        var localCtx = formatCtx
        let ret = avformat_open_input(&localCtx, path, fmt, &opts)
        formatCtx = localCtx
        av_dict_free(&opts)

        guard ret == 0 else {
            logger.error("avformat_open_input (concat) FAILED, ret=\(ret)")
            throw DemuxerError.openFailed(ret)
        }
        logger.info("avformat_open_input (concat) OK")

        try finishOpen(skipDurationProbe: skipDurationProbe, isNetwork: true,
                       knownDurationSecs: knownDurationSecs)
    }

    func open(reader: any MediaRandomAccessReader, skipDurationProbe: Bool = false,
              knownDurationSecs: Double? = nil) throws {
        _ = configureFFmpegLoggingOnce
        close()
        formatCtx = avformat_alloc_context()
        guard formatCtx != nil else { throw DemuxerError.openFailed(-1) }

        let bridge = AVIOBridge(reader: reader)
        guard let pb = bridge.createAVIOContext() else {
            throw DemuxerError.openFailed(-1)
        }
        avioBridge = bridge

        guard let ctx = formatCtx else { throw DemuxerError.openFailed(-1) }
        ctx.pointee.pb = pb
        ctx.pointee.flags |= 0x0080  // AVFMT_FLAG_CUSTOM_IO

        var opts: OpaquePointer?
        av_dict_set(&opts, "analyzeduration", "500000", 0)
        av_dict_set(&opts, "probesize", "262144", 0)

        logger.info("opening via custom I/O reader")

        var localCtx = formatCtx
        let ret = avformat_open_input(&localCtx, nil, nil, &opts)
        formatCtx = localCtx
        av_dict_free(&opts)

        guard ret == 0 else {
            logger.error("avformat_open_input (custom IO) FAILED, ret=\(ret)")
            throw DemuxerError.openFailed(ret)
        }
        logger.info("avformat_open_input OK (custom IO)")

        try finishOpen(skipDurationProbe: skipDurationProbe, isNetwork: true,
                       knownDurationSecs: knownDurationSecs)
    }

    private func finishOpen(skipDurationProbe: Bool, isNetwork: Bool,
                            knownDurationSecs: Double? = nil) throws {
        let infoRet = avformat_find_stream_info(formatCtx, nil)
        guard infoRet >= 0 else {
            logger.error("avformat_find_stream_info FAILED, ret=\(infoRet)")
            throw DemuxerError.noStreams(infoRet)
        }

        guard let ctx = formatCtx else { return }
        let nbStreams = ctx.pointee.nb_streams
        logger.info("found \(nbStreams) streams")

        for i in 0..<Int(nbStreams) {
            guard let stream = ctx.pointee.streams[i] else { continue }
            let codecType = stream.pointee.codecpar.pointee.codec_type
            let codecId = stream.pointee.codecpar.pointee.codec_id
            let cp = stream.pointee.codecpar.pointee
            logger.info("stream[\(i)]: type=\(codecType.rawValue) codec=\(codecId != AV_CODEC_ID_NONE ? String(cString: avcodec_get_name(codecId)) : "none") \(cp.width)x\(cp.height)")

            if codecType == AVMEDIA_TYPE_VIDEO && videoStream == nil {
                videoStream = stream
            } else if codecType == AVMEDIA_TYPE_AUDIO {
                // Prefer lightweight codecs for PCM decode (DTS > AC3 > AAC > TrueHD).
                // TrueHD is extremely expensive to software decode (8-channel MLP),
                // causing CPU starvation on iOS alongside 4K HEVC decoding.
                // Only pick TrueHD if no lighter codec is available.
                let score: Int
                switch codecId {
                case AV_CODEC_ID_AAC, AV_CODEC_ID_MP3: score = 4
                case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: score = 3
                case AV_CODEC_ID_DTS: score = 2
                case AV_CODEC_ID_TRUEHD: score = 1
                default: score = 3
                }
                if audioStream == nil || score > audioStreamScore {
                    audioStream = stream
                    audioStreamScore = score
                }
            }
        }

        applyStreamDiscard()

        duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        // Format-level duration may be 0 or AV_NOPTS_VALUE for HTTP/live streams.
        // Fall back to the longest stream duration estimated by avformat_find_stream_info.
        if duration <= 0 {
            var maxStreamDur: Double = 0
            for i in 0..<Int(nbStreams) {
                guard let s = ctx.pointee.streams[i] else { continue }
                let streamDur = Double(s.pointee.duration) * Double(s.pointee.time_base.num) / Double(max(s.pointee.time_base.den, 1))
                if streamDur > maxStreamDur { maxStreamDur = streamDur }
            }
            if maxStreamDur > 0 { duration = maxStreamDur }
        }
        let containerDur = duration
        // Seek to the end of THIS connection and read the last PTS — same technique
        // libmpv uses internally.  open() already runs on a background thread, so
        // this does not block the UI.  Uses a single Range request on the existing
        // HTTP connection; no second 115 session is opened.
        //
        // Skipped when:
        // - The caller already has a known duration (from Jellyfin API metadata)
        // - The URL is a network stream AND the container already reports a valid
        //   duration. For remote files (especially 4K HEVC on CDNs with moov at
        //   the end), seekRefine requires 2-3 extra HTTP round-trips (seek-to-end
        //   → read packets → seek-back) that can add 5-15s of latency. The container
        //   duration from the moov atom is accurate enough for playback; the small
        //   refinement (fixing placeholder durations) is not worth the wait.
        if !skipDurationProbe && !(isNetwork && containerDur > 0) {
            duration = seekRefine(ctx: ctx, hint: duration)
            if duration != containerDur {
                logger.info("duration refined: \(String(format: "%.1f", containerDur))s → \(String(format: "%.1f", self.duration))s")
            }
        } else {
            if skipDurationProbe {
                logger.info("duration probe skipped (knownDuration provided)")
                // av_seek_frame's generic (index-less) seek path — used by raw
                // mpegts/BDMV streams, which have no byte index — estimates the
                // target byte offset from ctx->duration. Skipping the probe above
                // leaves ctx->duration at whatever avformat_find_stream_info guessed
                // (often 0/invalid for a raw TS with no container-level duration
                // field), so every seek's ratio-estimate collapses to byte 0 and
                // seeking silently no-ops back to the start. Stamping the caller's
                // already-known duration onto ctx->duration fixes the estimate
                // without paying for a seek-to-end round trip.
                if let known = knownDurationSecs, known > 0 {
                    duration = known
                    ctx.pointee.duration = Int64(known * Double(AV_TIME_BASE))
                }
            } else {
                logger.info("duration probe skipped (network stream with container duration=\(String(format: "%.1f", containerDur))s)")
            }
        }
        logger.info("videoIdx=\(self.videoStreamIndex) audioIdx=\(self.audioStreamIndex) duration=\(String(format: "%.1f", self.duration))s")
    }

    // Seek to end of the current context, read the last PTS, then seek back.
    // Returns the refined duration or the original hint if seeking fails.
    private func seekRefine(ctx: UnsafeMutablePointer<AVFormatContext>, hint: Double) -> Double {
        let vidIdx = videoStream.map { Int32($0.pointee.index) } ?? -1
        guard av_seek_frame(ctx, vidIdx, Int64.max,
                            Int32(AVSEEK_FLAG_BACKWARD) | Int32(AVSEEK_FLAG_ANY)) >= 0 else {
            return hint
        }
        let nopts = Int64(bitPattern: 0x8000000000000000)
        var refined = hint
        var pkt = av_packet_alloc()
        var n = 0
        while n < 64, av_read_frame(ctx, pkt) >= 0 {
            if let p = pkt, (vidIdx < 0 || p.pointee.stream_index == vidIdx),
               p.pointee.pts != nopts {
                let s = ctx.pointee.streams[Int(p.pointee.stream_index)]!
                let t = Double(p.pointee.pts) * Double(s.pointee.time_base.num)
                    / Double(max(s.pointee.time_base.den, 1))
                if t > refined { refined = t }
            }
            av_packet_unref(pkt)
            n += 1
        }
        av_packet_free(&pkt)
        // Seek back to start so the demux loop begins from 0.
        av_seek_frame(ctx, -1, 0, Int32(AVSEEK_FLAG_BACKWARD))
        return refined
    }

    /// Reads the next packet. `didSwitchClip` is always `false` for a single
    /// file — a mono-file demuxer never switches clips mid-stream. The flag
    /// exists so `PacketDemuxing` callers (NativeBackend's demux loop) can
    /// treat the first packet after a `MultiClipDemuxer` clip boundary
    /// specially (its PTS is a known-good rebase onto the continuous
    /// timeline, not an anomaly).
    func readPacket() -> (streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>, didSwitchClip: Bool)? {
        guard let ctx = formatCtx else { return nil }
        var pkt = av_packet_alloc()
        let ret = av_read_frame(ctx, pkt)
        guard ret == 0, let packet = pkt else {
            if ret < 0 {
                logger.error("av_read_frame error: \(ret)")
            }
            av_packet_free(&pkt)
            return nil
        }
        return (packet.pointee.stream_index, packet, false)
    }

    // Probe real duration by opening a SEPARATE context on the same URL and
    // seeking to end.  Never touches the main playback context so the stream
    // and any server-side buffer are not disturbed.
    static func probeDuration(url: URL, headers: [String: String]) -> Double? {
        var probeCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard probeCtx != nil else { return nil }
        var opts: OpaquePointer?
        // analyzeduration=0 + probesize=32 → avformat_open_input reads only the
        // container header (a few KB), then we immediately seek to end.
        // This avoids downloading megabytes of stream data that would compete
        // with the main playback connection for bandwidth.
        av_dict_set(&opts, "analyzeduration", "0", 0)
        av_dict_set(&opts, "probesize", "65536", 0) // 64KB — enough to parse container header
        if !headers.isEmpty {
            let dict = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            av_dict_set(&opts, "headers", dict, 0)
        }
        guard avformat_open_input(&probeCtx, url.isFileURL ? url.path : url.absoluteString, nil, &opts) == 0 else {
            av_dict_free(&opts); return nil
        }
        av_dict_free(&opts)
        guard let ctx = probeCtx else { return nil }
        // max_analyze_duration=0 makes avformat_find_stream_info parse only the
        // container header (time_base, stream count) without reading any A/V samples.
        // This is required so that av_seek_frame can convert timestamps to byte offsets.
        ctx.pointee.max_analyze_duration = 0
        avformat_find_stream_info(ctx, nil)
        // vidIdx = -1 accepts packets from any stream.
        let vidIdx: Int32 = -1
        guard av_seek_frame(ctx, vidIdx, Int64.max, Int32(AVSEEK_FLAG_BACKWARD) | Int32(AVSEEK_FLAG_ANY)) >= 0 else {
            avformat_close_input(&probeCtx); return nil
        }
        let nopts = Int64(bitPattern: 0x8000000000000000)
        var refined: Double = 0
        var pkt = av_packet_alloc()
        var n = 0
        while n < 64, av_read_frame(ctx, pkt) >= 0 {
            if let p = pkt, (vidIdx < 0 || p.pointee.stream_index == vidIdx), p.pointee.pts != nopts {
                let s = ctx.pointee.streams[Int(p.pointee.stream_index)]!
                let t = Double(p.pointee.pts) * Double(s.pointee.time_base.num) / Double(max(s.pointee.time_base.den, 1))
                if t > refined { refined = t }
            }
            av_packet_unref(pkt)
            n += 1
        }
        av_packet_free(&pkt)
        avformat_close_input(&probeCtx)
        return refined > 0 ? refined : nil
    }

    func seek(to time: Double) -> Bool {
        guard let ctx = formatCtx else { return false }
        if isRawIndexlessStream, duration > 0, let pb = ctx.pointee.pb {
            return seekByByteOffset(to: time, ctx: ctx, pb: pb)
        }
        let targetTs = Int64(time * Double(AV_TIME_BASE))
        let ok = av_seek_frame(ctx, -1, targetTs, Int32(AVSEEK_FLAG_BACKWARD)) >= 0
        logger.info("seek to \(String(format: "%.1f", time))s \(ok ? "OK" : "FAILED")")
        return ok
    }

    /// True for headerless/indexless formats (raw MPEG-TS / BDMV clip streams).
    /// ffmpeg's generic seek estimates a byte offset by probing PTS near both
    /// ends of the file and interpolating — for a BD ISO rip whose trailing
    /// bytes are corrupt/truncated (the same corruption `AVIOBridge`'s EOF
    /// handling deals with), that end-of-file probe returns a garbage PTS,
    /// which poisons the interpolation so *every* seek converges on the
    /// wrong end of the file regardless of target. Confirmed by tracing every
    /// avio_seek call ffmpeg made: seeks below ~700s landed at byte 0, seeks
    /// above landed at EOF, regardless of actual target.
    private var isRawIndexlessStream: Bool {
        guard let name = formatCtx?.pointee.iformat?.pointee.name else { return false }
        return String(cString: name).contains("mpegts")
    }

    /// Seeks a raw MPEG-TS stream by computing the target byte offset
    /// ourselves — from the caller's known-accurate content duration and the
    /// file size — instead of trusting ffmpeg's own (unreliable here, see
    /// `isRawIndexlessStream`) PTS-probing estimate. `avformat_flush` is
    /// avformat.h's documented way to reset demuxer-internal buffering after
    /// manually repositioning the AVIOContext on a headerless, resyncable
    /// format like MPEG-TS.
    private func seekByByteOffset(to time: Double, ctx: UnsafeMutablePointer<AVFormatContext>,
                                  pb: UnsafeMutablePointer<AVIOContext>) -> Bool {
        let totalBytes = avioBridge?.totalBytes ?? -1
        guard totalBytes > 0, duration > 0 else { return false }
        let avgBytesPerSecond = Double(totalBytes) / duration

        var targetByte = Int64(Double(totalBytes) * min(max(time / duration, 0), 1))
        var landedPTS: Double?

        // A single linear byte-ratio guess is unreliable on VBR content — an
        // action-heavy stretch can run several times the average bitrate of a
        // dialogue stretch, and BD remuxes commonly swing enough to land the
        // guess tens of seconds from the target (observed: 21s overshoot on a
        // GoT remux). Refine against an actually-probed video PTS instead of
        // trusting the ratio blindly: seek, read forward for the first
        // decodable video PTS, and if it's off from `time` by more than a
        // small tolerance, correct the byte target using the observed error
        // (converted via the file's average bitrate) and try again. Each
        // round's probe reads are simply thrown away — only the final avio
        // position matters, since the real demux loop starts fresh from
        // wherever this function leaves pb/ctx.
        for attempt in 0..<3 {
            avio_flush(pb)
            guard avio_seek(pb, targetByte, 0 /* SEEK_SET */) >= 0 else {
                logger.error("seek to \(String(format: "%.1f", time))s FAILED (avio_seek)")
                return false
            }
            guard avformat_flush(ctx) >= 0 else {
                logger.error("seek to \(String(format: "%.1f", time))s FAILED (avformat_flush)")
                return false
            }
            guard let pts = probeVideoPTSSeconds(ctx: ctx) else { break }
            landedPTS = pts
            let errorSecs = pts - time
            if abs(errorSecs) < 1.5 || attempt == 2 { break }
            targetByte = min(max(targetByte - Int64(errorSecs * avgBytesPerSecond), 0), totalBytes - 1)
        }

        let ok = landedPTS != nil
        logger.info("seek to \(String(format: "%.1f", time))s \(ok ? "OK" : "FAILED") (byte-domain target=\(targetByte)/\(totalBytes)\(landedPTS.map { " landed=\(String(format: "%.1f", $0))s" } ?? ""))")
        return ok
    }

    /// Reads forward from the current position looking for the first packet
    /// on the selected video stream that carries a valid PTS, returning it
    /// converted to the same zero-based "seconds from playback start" domain
    /// `seek(to:)` uses (subtracting the stream's start_time, matching
    /// `NativeBackend.ptsFromPacket`). Bounded to 200 packets so a corrupt or
    /// heavily-interleaved region can't spin this forever; returns nil if no
    /// video PTS turns up in that window (e.g. probe landed at/past EOF).
    private func probeVideoPTSSeconds(ctx: UnsafeMutablePointer<AVFormatContext>) -> Double? {
        guard let vs = videoStream else { return nil }
        let vIdx = vs.pointee.index
        let nopts = Int64(bitPattern: 0x8000000000000000)
        let startOffset: Double = vs.pointee.start_time == nopts ? 0 :
            Double(vs.pointee.start_time) * Double(vs.pointee.time_base.num) / Double(max(vs.pointee.time_base.den, 1))

        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        var attempts = 0
        while attempts < 200, av_read_frame(ctx, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            attempts += 1
            guard let p = pkt, p.pointee.stream_index == vIdx, p.pointee.pts != nopts else { continue }
            let raw = Double(p.pointee.pts) * Double(vs.pointee.time_base.num) / Double(max(vs.pointee.time_base.den, 1))
            return raw - startOffset
        }
        return nil
    }

    func close() {
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
            formatCtx = nil
        }
        avioBridge?.free()
        avioBridge = nil
        videoStream = nil
        audioStream = nil
        audioStreamScore = 0
        subtitleStream = nil
        duration = 0
    }

    deinit { close() }
}
