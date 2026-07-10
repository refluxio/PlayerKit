import Foundation
import CoreMedia
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "demuxer")

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
    private(set) var duration: Double = 0

    var videoStreamIndex: Int32 { videoStream.map { $0.pointee.index } ?? -1 }
    var audioStreamIndex: Int32 { audioStream.map { $0.pointee.index } ?? -1 }

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

    /// Video stream's sample aspect ratio (SAR). Defaults to 1:1 if not set.
    /// Non-square pixels are common in H.264 SD content — e.g. 720×576 with
    /// SAR 16:15 gives a display aspect of 768×576 (4:3).
    var sampleAspectRatio: Double {
        guard let vs = videoStream else { return 1.0 }
        let sar = vs.pointee.sample_aspect_ratio
        guard sar.num > 0, sar.den > 0 else { return 1.0 }
        return Double(sar.num) / Double(sar.den)
    }

    func open(url: URL, headers: [String: String] = [:], skipDurationProbe: Bool = false) throws {
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
        av_dict_set(&opts, "analyzeduration", "5000000", 0)  // 5s
        av_dict_set(&opts, "probesize", "5000000", 0)         // 5MB

        if !headers.isEmpty {
            let dict = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
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
        // Skipped when the caller already has a known duration (from Jellyfin API
        // metadata) — saves 2-3 HTTP round-trips to the CDN (seek-to-end → read
        // packets → seek-back), which can add seconds on high-latency 115 links.
        if !skipDurationProbe {
            duration = seekRefine(ctx: ctx, hint: duration)
            if duration != containerDur {
                logger.info("duration refined: \(String(format: "%.1f", containerDur))s → \(String(format: "%.1f", self.duration))s")
            }
        } else {
            logger.info("duration probe skipped (knownDuration provided)")
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

    func readPacket() -> (streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>)? {
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
        return (packet.pointee.stream_index, packet)
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
            let dict = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
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
        let targetTs = Int64(time * Double(AV_TIME_BASE))
        let ok = av_seek_frame(ctx, -1, targetTs, Int32(AVSEEK_FLAG_BACKWARD)) >= 0
        logger.info("seek to \(String(format: "%.1f", time))s \(ok ? "OK" : "FAILED")")
        return ok
    }

    func close() {
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
            formatCtx = nil
        }
        videoStream = nil
        audioStream = nil
        audioStreamScore = 0
        duration = 0
    }

    deinit { close() }
}
