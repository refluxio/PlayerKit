import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "decoder.video.sw")

final class FFmpegVideoDecoder {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?
    let isHardware: Bool
    private var decodedFrames = 0

    /// Stream-level DoVi config (profile + BL signal compatibility id),
    /// read once from `AV_PKT_DATA_DOVI_CONF` in codecpar coded_side_data.
    /// Per-frame Level 1 / Level 6 come from `AV_FRAME_DATA_DOVI_METADATA`.
    private let doviConfig: DolbyVisionFrameMetadata?

    var width:  Int { Int(codecCtx?.pointee.width  ?? 0) }
    var height: Int { Int(codecCtx?.pointee.height ?? 0) }

    init?(stream: UnsafeMutablePointer<AVStream>, forceSoftware: Bool = false) {
        let codecpar = stream.pointee.codecpar.pointee

        // Extract stream-level DoVi configuration record (profile + bl_signal_compat_id).
        // This is constant per stream; attach to every emitted DolbyVisionFrameMetadata.
        self.doviConfig = Self.extractDoviConfig(from: stream.pointee.codecpar)

        // HEVC and H.264 are handled by VTVideoDecoder — its VT session
        // explicitly requests Metal-compatible IOSurface-backed pixel buffers
        // (kCVPixelBufferMetalCompatibilityKey), avoiding the alignment-padding
        // and buffer-pool inconsistencies of FFmpeg's hwaccel integration.
        //
        // When forceSoftware is true, accept HEVC/H.264 here so the decoder
        // acts as a software fallback — used when VT repeatedly fails (e.g.
        // 4K@120fps exceeding hardware limits).
        if !forceSoftware,
           codecpar.codec_id == AV_CODEC_ID_HEVC || codecpar.codec_id == AV_CODEC_ID_H264 {
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

        if forceSoftware {
            // Bypass VT hwaccel — open codec directly in software mode.
            let swRet = avcodec_open2(ctx, codec, nil)
            guard swRet == 0 else {
                logger.error("SW open failed (\(swRet))")
                FFmpegVideoDecoder.safeFree(&self.codecCtx)
                return nil
            }
            self.isHardware = false
            logger.notice("SW fallback OK \(ctx.pointee.width)x\(ctx.pointee.height) fmt=\(ctx.pointee.pix_fmt.rawValue)")
        } else {
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
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> DecodedVideoFrame? {
        guard let ctx = codecCtx else { return nil }
        guard avcodec_send_packet(ctx, packet) == 0 else { return nil }
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard avcodec_receive_frame(ctx, frame) == 0, let f = frame else { return nil }
        decodedFrames += 1
        if decodedFrames <= 3 {
            logger.info("frame #\(self.decodedFrames): \(f.pointee.width)x\(f.pointee.height) fmt=\(f.pointee.format)")
        }

        // Per-frame Level 1 / Level 6 come from AV_FRAME_DATA_DOVI_METADATA.
        // Stream-level profile / bl_signal_compatibility_id are in self.doviConfig.
        // If neither is present (non-DV stream), dovi == nil → HDR10/SDR path.
        let perFrame = extractDoviMetadata(from: f)
        let dovi: DolbyVisionFrameMetadata?
        if let cfg = doviConfig {
            var m = cfg
            m.level1 = perFrame?.level1
            m.level6 = perFrame?.level6
            dovi = m
        } else {
            dovi = nil
        }

        if f.pointee.format == Int32(AV_PIX_FMT_VIDEOTOOLBOX.rawValue) {
            guard let pb = extractHWPixelBuffer(from: f) else { return nil }
            return DecodedVideoFrame(pixelBuffer: pb, dovi: dovi)
        } else if Self.is10BitPlanar(f.pointee.format) {
            guard let pb = create10BitBiplanarBuffer(from: f) else { return nil }
            return DecodedVideoFrame(pixelBuffer: pb, dovi: dovi)
        } else {
            guard let pb = convertSWFrame(f) else { return nil }
            return DecodedVideoFrame(pixelBuffer: pb, dovi: dovi)
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

    // MARK: - 10-bit biplanar output

    /// True when the FFmpeg pixel format is a 10-bit planar YUV variant that the
    /// MetalRenderer HDR tone-map path can interpret natively via CIImage +
    /// BT.2020 color space.  Keeping the native format avoids the BGRA round-trip
    /// that loses HDR metadata and produces washed-out colours.
    private static func is10BitPlanar(_ fmt: Int32) -> Bool {
        let f = AVPixelFormat(rawValue: fmt)
        return f == AV_PIX_FMT_YUV420P10LE || f == AV_PIX_FMT_YUV420P10BE
    }

    /// Create a `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` pixel buffer
    /// from the FFmpeg 10-bit planar frame.  Colour attachments are set to
    /// BT.2020 / PQ so CoreImage + MetalRenderer HDR tone-map correctly.
    private func create10BitBiplanarBuffer(from frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
        guard w > 0, h > 0 else { return nil }

        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                   kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                   attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }

        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let yStride  = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

        Self.pack10BitPlane(src: frame.pointee.data.0, srcStride: Int(frame.pointee.linesize.0),
                            dst: yDst, dstStride: yStride, width: w, height: h)
        Self.pack10BitUVPlane(srcU: frame.pointee.data.1, srcV: frame.pointee.data.2,
                               srcStrideU: Int(frame.pointee.linesize.1),
                               srcStrideV: Int(frame.pointee.linesize.2),
                               dst: uvDst, dstStride: uvStride,
                               uvWidth: (w + 1) / 2, height: (h + 1) / 2)

        return pb
    }

    /// Pack Y plane: width × height samples, 3 × 10-bit → one UInt32 LE.
    private static func pack10BitPlane(src: UnsafeMutablePointer<UInt8>!, srcStride: Int,
                                        dst: UnsafeMutableRawPointer, dstStride: Int,
                                        width: Int, height: Int) {
        for y in 0..<height {
            let srcRow = src.advanced(by: y * srcStride)
            let dstRow = dst.advanced(by: y * dstStride).assumingMemoryBound(to: UInt32.self)
            pack10BitRow(srcRow: srcRow, dstRow: dstRow, count: width)
        }
    }

    /// Pack UV plane: interleave U and V, then pack 3 × 10-bit → one UInt32 LE.
    private static func pack10BitUVPlane(srcU: UnsafeMutablePointer<UInt8>!, srcV: UnsafeMutablePointer<UInt8>!,
                                          srcStrideU: Int, srcStrideV: Int,
                                          dst: UnsafeMutableRawPointer, dstStride: Int,
                                          uvWidth: Int, height: Int) {
        for y in 0..<height {
            let uRow = srcU.advanced(by: y * srcStrideU)
            let vRow = srcV.advanced(by: y * srcStrideV)
            let dstRow = dst.advanced(by: y * dstStride).assumingMemoryBound(to: UInt32.self)

            // Build interleaved sample stream: U[0], V[0], U[1], V[1], ...
            var samples = [UInt32]()
            samples.reserveCapacity(uvWidth * 2)
            for i in 0..<uvWidth {
                samples.append(UInt32(Self.readU16LE(uRow, offset: i * 2)) & 0x3FF)
                samples.append(UInt32(Self.readU16LE(vRow, offset: i * 2)) & 0x3FF)
            }
            while samples.count % 3 != 0 { samples.append(0) }

            var di = 0
            for ri in stride(from: 0, to: samples.count, by: 3) {
                dstRow[di] = samples[ri] | (samples[ri + 1] << 10) | (samples[ri + 2] << 20)
                di += 1
            }
        }
    }

    /// Read a UInt16 LE from an UnsafeMutablePointer<UInt8> at the given byte offset.
    private static func readU16LE(_ ptr: UnsafeMutablePointer<UInt8>, offset: Int) -> UInt16 {
        UnsafeRawPointer(ptr).load(fromByteOffset: offset, as: UInt16.self)
    }

    /// Pack `count` 10-bit samples (UInt16 LE, low 10 bits) into UInt32 LE words (3 per word).
    private static func pack10BitRow(srcRow: UnsafeMutablePointer<UInt8>,
                                      dstRow: UnsafeMutablePointer<UInt32>,
                                      count: Int) {
        var si = 0, di = 0
        while si + 2 < count {
            let s0 = UInt32(readU16LE(srcRow, offset: si * 2)) & 0x3FF; si += 1
            let s1 = UInt32(readU16LE(srcRow, offset: si * 2)) & 0x3FF; si += 1
            let s2 = UInt32(readU16LE(srcRow, offset: si * 2)) & 0x3FF; si += 1
            dstRow[di] = s0 | (s1 << 10) | (s2 << 20)
            di += 1
        }
        // Remainder (1–2 samples) — pad with zero
        if si < count {
            var rem = [UInt32]()
            while si < count {
                rem.append(UInt32(readU16LE(srcRow, offset: si * 2)) & 0x3FF)
                si += 1
            }
            while rem.count < 3 { rem.append(0) }
            dstRow[di] = rem[0] | (rem[1] << 10) | (rem[2] << 20)
        }
    }

    func flush() {
        if let ctx = codecCtx { avcodec_flush_buffers(ctx) }
    }

    // MARK: - Dolby Vision metadata extraction

    /// Read stream-level `AVDOVIDecoderConfigurationRecord` from codecpar
    /// `coded_side_data`. This carries `dv_profile` and
    /// `dv_bl_signal_compatibility_id`, both constant per stream. Returns nil
    /// for non-Dolby-Vision streams (no DOVI_CONF side data).
    private static func extractDoviConfig(from codecpar: UnsafeMutablePointer<AVCodecParameters>?) -> DolbyVisionFrameMetadata? {
        guard let cp = codecpar else { return nil }
        let nb = Int(cp.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = cp.pointee.coded_side_data else { return nil }
        for i in 0..<nb {
            let sd = sideData[i]
            if sd.type == AV_PKT_DATA_DOVI_CONF, let data = sd.data {
                let cfg = data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
                var m = DolbyVisionFrameMetadata()
                m.profile = cfg.dv_profile
                m.blSignalCompatibilityId = cfg.dv_bl_signal_compatibility_id
                logger.info("DV stream config: profile=\(cfg.dv_profile) bl_compat_id=\(cfg.dv_bl_signal_compatibility_id) el=\(cfg.el_present_flag)")
                return m
            }
        }
        return nil
    }

    /// Extract per-frame Level 1 (dynamic brightness) and Level 6 (static HDR10)
    /// from `AV_FRAME_DATA_DOVI_METADATA` side data attached to the decoded
    /// AVFrame. Profile and bl_signal_compatibility_id are stream-level and
    /// already set in `doviConfig`; this returns a struct carrying only L1/L6.
    /// Must be called before `av_frame_free`.
    private func extractDoviMetadata(from frame: UnsafeMutablePointer<AVFrame>) -> DolbyVisionFrameMetadata? {
        guard let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
              let data = sd.pointee.data else { return nil }
        let meta = UnsafeRawPointer(data).assumingMemoryBound(to: AVDOVIMetadata.self)

        var l1: DolbyVisionFrameMetadata.Level1?
        if let dm = av_dovi_find_level(meta, 1), dm.pointee.level == 1 {
            l1 = DolbyVisionFrameMetadata.Level1(
                minPq: dm.pointee.l1.min_pq,
                maxPq: dm.pointee.l1.max_pq,
                avgPq: dm.pointee.l1.avg_pq
            )
        }

        var l6: DolbyVisionFrameMetadata.Level6?
        if let dm = av_dovi_find_level(meta, 6), dm.pointee.level == 6 {
            l6 = DolbyVisionFrameMetadata.Level6(
                maxLuminance: dm.pointee.l6.max_luminance,
                minLuminance: dm.pointee.l6.min_luminance,
                maxCll:       dm.pointee.l6.max_cll,
                maxFall:      dm.pointee.l6.max_fall
            )
        }

        if decodedFrames <= 3 {
            logger.info("DV frame L1: \(l1.map { "min=\($0.minPq) max=\($0.maxPq) avg=\($0.avgPq)" } ?? "nil") L6: \(l6.map { "maxLum=\($0.maxLuminance) cll=\($0.maxCll)" } ?? "nil")")
        }

        var m = DolbyVisionFrameMetadata()
        m.level1 = l1
        m.level6 = l6
        return m
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
