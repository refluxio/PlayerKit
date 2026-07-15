// Sources/PlayerKitNative/FFmpegSubtitleDecoder.swift
import Foundation
import CoreGraphics
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
        self.timeBase = stream.pointee.time_base
        self.videoSize = videoSize
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

        let startPts = Double(packet.pointee.pts) * tbSecs
        let endDisplayMs = Double(sub.end_display_time)
        let endPts: Double
        if endDisplayMs > 0 {
            endPts = startPts + endDisplayMs / 1000.0
        } else if packet.pointee.duration > 0 {
            endPts = startPts + Double(packet.pointee.duration) * tbSecs
        } else {
            endPts = startPts + 5.0
        }

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
