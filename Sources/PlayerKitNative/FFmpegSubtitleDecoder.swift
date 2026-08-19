// Sources/PlayerKitNative/FFmpegSubtitleDecoder.swift
import Foundation
import CoreGraphics
import os
import CFFmpeg

/// Decodes PGS/VOBSUB bitmap subtitle packets via avcodec_decode_subtitle2.
/// One instance per selected subtitle stream; recreate on stream switch.
final class FFmpegSubtitleDecoder: @unchecked Sendable {

    struct Cue {
        let startPts: Double
        let endPts: Double
        let image: CGImage
        /// Normalized position within the video frame (origin top-left, 0...1 each axis).
        let rect: CGRect
    }

    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private let timeBase: AVRational
    private let videoSize: CGSize
    // Subtracted from every packet's raw PTS, same normalization NativeBackend's
    // video ptsFromPacket() applies via videoStream.start_time. Without this,
    // a subtitle stream whose start_time differs from the video/audio streams'
    // (common in MKV remuxes of BD PGS tracks — mkvmerge often preserves the
    // original disc-absolute PGS timestamps while renormalizing video/audio to
    // start at 0) produces cues timed hundreds of seconds away from the actual
    // playback position: they decode fine and get appended to the cue buffer,
    // but the display-time match in NativeBackend never finds them, so nothing
    // ever renders. Observed: video at t=696s, subtitle cues stamped ~1296s —
    // a ~600s constant offset consistent with the subtitle stream's start_time.
    private let startOffsetSecs: Double

    init?(stream: UnsafeMutablePointer<AVStream>, videoSize: CGSize) {
        guard let par = stream.pointee.codecpar else { return nil }
        guard let codec = avcodec_find_decoder(par.pointee.codec_id),
              let c = avcodec_alloc_context3(codec) else { return nil }
        guard avcodec_parameters_to_context(c, par) >= 0,
              avcodec_open2(c, codec, nil) >= 0 else {
            var mc: UnsafeMutablePointer<AVCodecContext>? = c
            avcodec_free_context(&mc)
            return nil
        }
        self.ctx = c
        let tb = stream.pointee.time_base
        self.timeBase = tb
        self.videoSize = videoSize
        let nopts = Int64(bitPattern: 0x8000000000000000)
        if stream.pointee.start_time != nopts, tb.den > 0 {
            self.startOffsetSecs = Double(stream.pointee.start_time) * Double(tb.num) / Double(tb.den)
        } else {
            self.startOffsetSecs = 0
        }
    }

    deinit {
        avcodec_free_context(&ctx)
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> Cue? {
        guard let ctx else { return nil }
        var sub = AVSubtitle()
        var gotSub: Int32 = 0
        guard avcodec_decode_subtitle2(ctx, &sub, &gotSub, packet) >= 0,
              gotSub != 0 else { return nil }
        defer { avsubtitle_free(&sub) }

        guard sub.num_rects > 0,
              let rects = sub.rects else { return nil }
        // Only the first rect is decoded. PGS can theoretically emit two rects
        // for dual-line subtitles; multi-rect handling is a known limitation.
        guard let rectPtr = rects[0],
              rectPtr.pointee.type == SUBTITLE_BITMAP else { return nil }

        let r = rectPtr.pointee
        let w = Int(r.w), h = Int(r.h)
        guard w > 0, h > 0,
              let pixels = r.data.0,      // palette-indexed pixels
              let palette = r.data.1 else { return nil }  // BGRA palette (256 × 4 bytes, little-endian)

        // data[0] = palette-indexed pixels, data[1] = BGRA palette (256 × 4 bytes, little-endian)
        let stride = Int(r.linesize.0)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let idx = Int(pixels[row * stride + col]) * 4
                let base = (row * w + col) * 4
                rgba[base + 0] = palette[idx + 2]  // R (palette byte 2)
                rgba[base + 1] = palette[idx + 1]  // G
                rgba[base + 2] = palette[idx + 0]  // B (palette byte 0)
                rgba[base + 3] = palette[idx + 3]  // A
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        let tb = timeBase
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let packetPts = Double(packet.pointee.pts) * tbSecs - startOffsetSecs
        let startPts = packetPts + Double(sub.start_display_time) / 1000.0
        let endPts: Double
        // PGS (and some VOBSUB) decoders set end_display_time to UINT32_MAX
        // when there is no explicit subtitle end packet — the subtitle should
        // stay on screen until the next PGS event.  Matroska sets packet.duration
        // to the interval between consecutive PGS events, so prefer that value.
        // Only use end_display_time when it is a plausible display duration
        // (< 24 hours = 86_400_000 ms).
        let endDisplayMs = Double(sub.end_display_time)
        let pktDuration = packet.pointee.duration
        if endDisplayMs > 0, endDisplayMs < 86_400_000 {
            endPts = startPts + endDisplayMs / 1000.0
        } else if pktDuration > 0 {
            endPts = startPts + Double(pktDuration) * tbSecs
        } else {
            endPts = startPts + 10.0
        }

        // Timing diagnostics
        let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "subtitle")
        logger.debug("[pgsdec] pkt.pts=\(packet.pointee.pts) packetPts=\(String(format:"%.3f",packetPts)) sub.start_display_time=\(sub.start_display_time) pkt.duration=\(pktDuration) end_display_time=\(sub.end_display_time) → startPts=\(String(format:"%.3f",startPts)) endPts=\(String(format:"%.3f",endPts))")

        let normRect: CGRect
        if videoSize.width > 0, videoSize.height > 0 {
            normRect = CGRect(
                x: Double(r.x) / videoSize.width,
                y: Double(r.y) / videoSize.height,
                width: Double(w) / videoSize.width,
                height: Double(h) / videoSize.height
            )
        } else {
            normRect = CGRect(x: 0, y: 0.82, width: 1.0, height: 0.12)
        }

        return Cue(startPts: startPts, endPts: endPts,
                   image: cgImage, rect: normRect)
    }
}
