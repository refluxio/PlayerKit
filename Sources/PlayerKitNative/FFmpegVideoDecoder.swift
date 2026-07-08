import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "decoder.video.sw")

final class FFmpegVideoDecoder {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?
    let isHardware: Bool
    private var decodedFrames = 0

    var width:  Int { Int(codecCtx?.pointee.width  ?? 0) }
    var height: Int { Int(codecCtx?.pointee.height ?? 0) }

    init?(stream: UnsafeMutablePointer<AVStream>) {
        let codecpar = stream.pointee.codecpar.pointee

        // HEVC and H.264 are handled by VTVideoDecoder — its VT session
        // explicitly requests Metal-compatible IOSurface-backed pixel buffers
        // (kCVPixelBufferMetalCompatibilityKey), avoiding the alignment-padding
        // and buffer-pool inconsistencies of FFmpeg's hwaccel integration.
        if codecpar.codec_id == AV_CODEC_ID_HEVC || codecpar.codec_id == AV_CODEC_ID_H264 {
            logger.info("\(codecpar.codec_id == AV_CODEC_ID_HEVC ? "HEVC" : "H.264") — delegating to VTVideoDecoder")
            return nil
        }

        guard let codec = avcodec_find_decoder(codecpar.codec_id) else {
            logger.error("codec not found: \(codecpar.codec_id.rawValue)")
            return nil
        }
        logger.info("codec=\(String(cString: avcodec_get_name(codecpar.codec_id))) \(codecpar.width)x\(codecpar.height)")

        guard let ctx = avcodec_alloc_context3(codec) else { return nil }
        self.codecCtx = ctx

        // FFmpeg 8.x standard: avcodec_parameters_to_context handles coded_side_data.
        // Temporarily zero coded_side_data to avoid null-data entries crashing the copy.
        let cp = stream.pointee.codecpar!
        let savedSD   = cp.pointee.coded_side_data
        let savedNbSD = cp.pointee.nb_coded_side_data
        cp.pointee.coded_side_data    = nil
        cp.pointee.nb_coded_side_data = 0
        let pRet = avcodec_parameters_to_context(ctx, cp)
        cp.pointee.coded_side_data    = savedSD
        cp.pointee.nb_coded_side_data = savedNbSD

        guard pRet >= 0 else {
            logger.error("avcodec_parameters_to_context FAILED ret=\(pRet)")
            FFmpegVideoDecoder.safeFree(&self.codecCtx)
            return nil
        }
        logger.info("ctx dims: \(ctx.pointee.width)x\(ctx.pointee.height)")

        // Detect sentinel extradata from FFmpeg 8.x coded_side_data API.
        // If extradata is a low-address sentinel, avcodec_open2 would crash.
        if let ext = ctx.pointee.extradata {
            let addr = UInt(bitPattern: ext)
            if addr < 0x100000000 {
                logger.info("sentinel extradata 0x\(String(addr, radix:16)) — falling back to VTVideoDecoder")
                FFmpegVideoDecoder.safeFree(&self.codecCtx)
                return nil
            }
        }

        ctx.pointee.time_base = stream.pointee.time_base

        // Try VideoToolbox hardware acceleration first.
        var hwCtx: UnsafeMutablePointer<AVBufferRef>?
        if av_hwdevice_ctx_create(&hwCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) == 0,
           let hwCtx {
            ctx.pointee.hw_device_ctx = av_buffer_ref(hwCtx)
            self.hwDeviceCtx = hwCtx
        }

        let openRet = avcodec_open2(ctx, codec, nil)
        if openRet == 0 {
            self.isHardware = (hwDeviceCtx != nil)
            logger.info("opened OK hw=\(self.isHardware) \(ctx.pointee.width)x\(ctx.pointee.height)")
        } else if hwDeviceCtx != nil {
            // HW failed — retry software
            logger.error("HW open failed (\(openRet)), retrying SW")
            av_buffer_unref(&ctx.pointee.hw_device_ctx)
            av_buffer_unref(&self.hwDeviceCtx)
            let swRet = avcodec_open2(ctx, codec, nil)
            if swRet == 0 {
                self.isHardware = false
                logger.info("SW fallback OK \(ctx.pointee.width)x\(ctx.pointee.height)")
            } else {
                logger.error("SW open also failed (\(swRet))")
                FFmpegVideoDecoder.safeFree(&self.codecCtx)
                return nil
            }
        } else {
            logger.error("avcodec_open2 FAILED (\(openRet))")
            FFmpegVideoDecoder.safeFree(&self.codecCtx)
            return nil
        }
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> CVPixelBuffer? {
        guard let ctx = codecCtx else { return nil }
        guard avcodec_send_packet(ctx, packet) == 0 else { return nil }
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard avcodec_receive_frame(ctx, frame) == 0, let f = frame else { return nil }
        decodedFrames += 1
        if decodedFrames <= 3 {
            logger.info("frame #\(self.decodedFrames): \(f.pointee.width)x\(f.pointee.height) fmt=\(f.pointee.format)")
        }
        if f.pointee.format == Int32(AV_PIX_FMT_VIDEOTOOLBOX.rawValue) {
            return extractHWPixelBuffer(from: f)
        } else {
            return convertSWFrame(f)
        }
    }

    private func extractHWPixelBuffer(from frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        // AVFrame.data.3 holds a CVPixelBuffer returned by VideoToolbox. The
        // buffer is owned by the AVFrame: av_frame_free() drops the AVFrame's
        // reference, but VideoToolbox itself still holds one (the pool will
        // reuse the buffer once the refcount hits 1).
        //
        // takeRetainedValue() (+1) detaches the buffer from the AVFrame's
        // lifetime so it survives av_frame_free(). The decoded frame then
        // travels through JitterBuffer → MetalRenderer → CIImage.render(),
        // which encodes a GPU read into an async MTLCommandBuffer. Without
        // this +1, VideoToolbox could reuse the buffer while the GPU is still
        // reading it → torn frames / 花屏 / flicker.
        guard let ptr = frame.pointee.data.3 else { return nil }
        return Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeRetainedValue()
    }

    private func convertSWFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
        guard w > 0, h > 0 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                   kCVPixelFormatType_32BGRA,
                                   attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var srcSlice: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0),
            UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2),
        ]
        var srcStride = [Int32(frame.pointee.linesize.0),
                         Int32(frame.pointee.linesize.1),
                         Int32(frame.pointee.linesize.2)]
        var dstStride = Int32(stride)
        guard let sws = sws_getContext(
            Int32(w), Int32(h), AVPixelFormat(rawValue: frame.pointee.format),
            Int32(w), Int32(h), AV_PIX_FMT_BGRA,
            Int32(SWS_BICUBIC.rawValue), nil, nil, nil
        ) else { return nil }
        defer { sws_freeContext(sws) }
        sws_scale(sws, &srcSlice, &srcStride, 0, Int32(h),
                  [base.assumingMemoryBound(to: UInt8.self)], &dstStride)
        return pb
    }

    func flush() {
        if let ctx = codecCtx { avcodec_flush_buffers(ctx) }
    }

    deinit {
        FFmpegVideoDecoder.safeFree(&self.codecCtx)
        if hwDeviceCtx != nil { av_buffer_unref(&self.hwDeviceCtx) }
        logger.info("deinit, decoded \(self.decodedFrames) frames")
    }

    // Safely free a codec context that may have sentinel extradata.
    private static func safeFree(_ ctx: inout UnsafeMutablePointer<AVCodecContext>?) {
        guard var c = ctx else { return }
        let extPtr = UInt(bitPattern: c.pointee.extradata)
        if c.pointee.extradata != nil && extPtr < 0x100000000 {
            c.pointee.extradata      = nil
            c.pointee.extradata_size = 0
        }
        avcodec_free_context(&ctx)
    }
}

extension FFmpegVideoDecoder: VideoDecoding {}
