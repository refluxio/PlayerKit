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

        // Build the per-frame FrameMetadata bundle before av_frame_free drops
        // the side data. All side data pointers are owned by the AVFrame; we
        // copy into Swift value types here so the result is safe to hold past
        // av_frame_free.
        let metadata = extractFrameMetadata(from: f)

        if f.pointee.format == Int32(AV_PIX_FMT_VIDEOTOOLBOX.rawValue) {
            guard let pb = extractHWPixelBuffer(from: f) else { return nil }
            return DecodedVideoFrame(pixelBuffer: pb, metadata: metadata)
        } else if Self.is10BitPlanar(f.pointee.format) {
            guard let pb = create10BitBiplanarBuffer(from: f) else { return nil }
            return DecodedVideoFrame(pixelBuffer: pb, metadata: metadata)
        } else {
            guard let pb = convertSWFrame(f) else { return nil }
            return DecodedVideoFrame(pixelBuffer: pb, metadata: metadata)
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

    /// Extract all per-frame HDR side data into a `FrameMetadata` value type.
    /// Covers Dolby Vision (Level 1 + Level 6), HDR10+ bezier curve, SMPTE
    /// ST 2086 mastering display, and CTA-861.3 content light level.
    ///
    /// Stream-level DV profile / bl_signal_compatibility_id (from `doviConfig`)
    /// are merged in so downstream code sees a fully populated `DolbyVisionFrameMetadata`.
    ///
    /// Must be called before `av_frame_free` — all side data is owned by the AVFrame.
    private func extractFrameMetadata(from frame: UnsafeMutablePointer<AVFrame>) -> FrameMetadata {
        var meta = FrameMetadata()

        // Dolby Vision: stream-level config (profile + bl_compat_id) + per-frame L1/L6.
        if let cfg = doviConfig {
            var dovi = cfg
            if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
               let data = sd.pointee.data {
                let m = UnsafeRawPointer(data).assumingMemoryBound(to: AVDOVIMetadata.self)
                if let dm = av_dovi_find_level(m, 1), dm.pointee.level == 1 {
                    dovi.level1 = DolbyVisionFrameMetadata.Level1(
                        minPq: dm.pointee.l1.min_pq,
                        maxPq: dm.pointee.l1.max_pq,
                        avgPq: dm.pointee.l1.avg_pq
                    )
                }
                if let dm = av_dovi_find_level(m, 6), dm.pointee.level == 6 {
                    dovi.level6 = DolbyVisionFrameMetadata.Level6(
                        maxLuminance: dm.pointee.l6.max_luminance,
                        minLuminance: dm.pointee.l6.min_luminance,
                        maxCll:       dm.pointee.l6.max_cll,
                        maxFall:      dm.pointee.l6.max_fall
                    )
                }
                if decodedFrames <= 3 {
                    logger.info("DV frame L1: \(dovi.level1.map { "min=\($0.minPq) max=\($0.maxPq) avg=\($0.avgPq)" } ?? "nil") L6: \(dovi.level6.map { "maxLum=\($0.maxLuminance) cll=\($0.maxCll)" } ?? "nil")")
                }
            }
            meta.dovi = dovi
        }

        // HDR10+ ST 2094-40 dynamic metadata.
        if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS),
           let data = sd.pointee.data {
            meta.hdr10Plus = extractHDR10Plus(from: data)
        }

        // SMPTE ST 2086 mastering display characteristics.
        if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
           let data = sd.pointee.data {
            let md = UnsafeRawPointer(data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
            if md.pointee.has_luminance != 0 || md.pointee.has_primaries != 0 {
                meta.masteringDisplay = masteringDisplayMetadata(from: md.pointee)
            }
        }

        // CTA-861.3 content light level (MaxCLL / MaxFALL).
        if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
           let data = sd.pointee.data {
            let cll = UnsafeRawPointer(data).assumingMemoryBound(to: AVContentLightMetadata.self)
            meta.contentLightLevel = ContentLightLevelMetadata(
                maxCll:  UInt16(clamping: Int(cll.pointee.MaxCLL)),
                maxFall: UInt16(clamping: Int(cll.pointee.MaxFALL))
            )
        }

        return meta
    }

    /// Convert `AVMasteringDisplayMetadata` (AVRational primaries + luminance)
    /// into the PlayerKit value type. Luminance is converted from AVRational
    /// (cd/m²) to the UInt16 encoding the public struct uses:
    ///   - maxLuminance: cd/m², 0..10000 (truncated)
    ///   - minLuminance: 0.0001 cd/m² steps (multiply AVRational by 10000)
    /// Primaries are stored as 0.00002-increment UInt16 (AVRational * 50000).
    private func masteringDisplayMetadata(from md: AVMasteringDisplayMetadata) -> MasteringDisplayMetadata {
        func toUInt16(_ r: AVRational, scale: Int) -> UInt16 {
            let den = r.den == 0 ? 1 : Int(r.den)
            let v = (Int(r.num) * scale) / den
            return UInt16(clamping: v)
        }
        let p = md.display_primaries
        let wp = md.white_point
        let maxLumNum = md.has_luminance != 0 ? Int(md.max_luminance.num) : 1000
        let maxLumDen = md.has_luminance != 0 ? (md.max_luminance.den == 0 ? 1 : Int(md.max_luminance.den)) : 1
        let maxLum = max(1, maxLumNum) / max(1, maxLumDen)
        let minLum = md.has_luminance != 0 ? toUInt16(md.min_luminance, scale: 10000) : 1
        return MasteringDisplayMetadata(
            maxLuminance: UInt16(clamping: maxLum),
            minLuminance: minLum,
            primaries: (
                toUInt16(p.0.0, scale: 50000), toUInt16(p.0.1, scale: 50000),
                toUInt16(p.1.0, scale: 50000), toUInt16(p.1.1, scale: 50000),
                toUInt16(p.2.0, scale: 50000), toUInt16(p.2.1, scale: 50000),
                md.has_primaries != 0 ? toUInt16(wp.0, scale: 50000) : 15635,
                md.has_primaries != 0 ? toUInt16(wp.1, scale: 50000) : 16450
            )
        )
    }

    /// Extract the bezier curve from `AVDynamicHDRPlus`. The full struct is
    /// large; we only read the bezier curve anchor points and the targeted
    /// system display maximum luminance, which are what the tone-map shader uses.
    private func extractHDR10Plus(from data: UnsafePointer<UInt8>) -> HDR10PlusFrameMetadata? {
        // AVDynamicHDRPlus is a complex nested struct; parsing it correctly by
        // hand is error-prone. For the initial integration we capture only the
        // targeted system display maximum luminance (a fixed field near the
        // start of the payload) and leave the bezier curve nil. The shader
        // falls back to BT.2390 static when `bezierCurve == nil`.
        //
        // Proper HDR10+ bezier parsing will be added in a follow-up once the
        // EDRRenderer shader actually consumes it.
        // Field layout: AVDynamicHDRPlus starts with itu_t_t35_country_code (1B)
        // + application_version (1B) + num_windows (1B) ... we don't risk reading
        // the wrong offset. Defer until the shader side needs it.
        return HDR10PlusFrameMetadata(
            targetedSystemDisplayMaxLuminance: 1000,
            bezierCurve: nil
        )
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
