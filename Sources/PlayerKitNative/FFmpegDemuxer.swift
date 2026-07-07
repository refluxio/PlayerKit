import Foundation
import CoreMedia
import CFFmpeg

enum DemuxerError: Error {
    case openFailed(Int32)
    case noStreams
}

final class FFmpegDemuxer: @unchecked Sendable {
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private(set) var duration: Double = 0

    var videoStreamIndex: Int32 { videoStream.map { $0.pointee.index } ?? -1 }
    var audioStreamIndex: Int32 { audioStream.map { $0.pointee.index } ?? -1 }

    private(set) var videoStream: UnsafeMutablePointer<AVStream>?
    private(set) var audioStream: UnsafeMutablePointer<AVStream>?

    func open(url: URL, headers: [String: String] = [:]) throws {
        close()
        formatCtx = avformat_alloc_context()
        guard formatCtx != nil else { throw DemuxerError.openFailed(-1) }

        // Set probe options via AVDictionary (must be before avformat_open_input)
        var opts: OpaquePointer?
        av_dict_set(&opts, "analyzeduration", "60000000", 0)  // 60s
        av_dict_set(&opts, "probesize", "100000000", 0)        // 100MB

        if !headers.isEmpty {
            let dict = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            av_dict_set(&opts, "headers", dict, 0)
        }

        let ret = avformat_open_input(&formatCtx, url.absoluteString, nil, &opts)
        av_dict_free(&opts)

        guard ret == 0 else {
            NSLog("[Demuxer] avformat_open_input FAILED, ret=\(ret)")
            throw DemuxerError.openFailed(ret)
        }
        NSLog("[Demuxer] avformat_open_input OK")

        let infoRet = avformat_find_stream_info(formatCtx, nil)
        guard infoRet >= 0 else {
            NSLog("[Demuxer] avformat_find_stream_info FAILED, ret=\(infoRet)")
            throw DemuxerError.noStreams
        }

        guard let ctx = formatCtx else { return }
        let nbStreams = ctx.pointee.nb_streams
        NSLog("[Demuxer] found \(nbStreams) streams")

        for i in 0..<Int(nbStreams) {
            guard let stream = ctx.pointee.streams[i] else { continue }
            let codecType = stream.pointee.codecpar.pointee.codec_type
            let codecId = stream.pointee.codecpar.pointee.codec_id
            let cp = stream.pointee.codecpar.pointee
            NSLog("[Demuxer] stream[\(i)]: type=\(codecType.rawValue) codec=\(codecId != AV_CODEC_ID_NONE ? String(cString: avcodec_get_name(codecId)) : "none") \(cp.width)x\(cp.height)")

            if codecType == AVMEDIA_TYPE_VIDEO && videoStream == nil {
                videoStream = stream
            } else if codecType == AVMEDIA_TYPE_AUDIO && audioStream == nil {
                audioStream = stream
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
        duration = seekRefine(ctx: ctx, hint: duration)
        if duration != containerDur {
            NSLog("[Demuxer] duration refined: \(String(format: "%.1f", containerDur))s → \(String(format: "%.1f", duration))s")
        }
        NSLog("[Demuxer] videoIdx=\(videoStreamIndex) audioIdx=\(audioStreamIndex) duration=\(String(format: "%.1f", duration))s")
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
                NSLog("[Demuxer] av_read_frame error: \(ret)")
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
        guard avformat_open_input(&probeCtx, url.absoluteString, nil, &opts) == 0 else {
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
        NSLog("[Demuxer] seek to \(String(format: "%.1f", time))s \(ok ? "OK" : "FAILED")")
        return ok
    }

    func close() {
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
            formatCtx = nil
        }
        videoStream = nil
        audioStream = nil
        duration = 0
    }

    deinit { close() }
}
