import Foundation
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "decoder.audio")

struct PCMFrame {
    let data: Data
    let pts: Double
    let sampleCount: Int
}

// AAC sampling-frequency-index → Hz (ISO 14496-3 §1.6.5.1)
private let aacSFRates: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000,
                                    24000, 22050, 16000, 12000, 11025, 8000, 7350]

private func resolveHz(_ raw: Int32, fallback: Int32) -> Int32 {
    if raw > 100 { return raw }
    if raw > 0, Int(raw) < aacSFRates.count { return aacSFRates[Int(raw)] }
    return fallback > 8000 ? fallback : 48000
}

// Parse sample rate from AudioSpecificConfig (ISO 14496-3 §1.6.5.1).
// Bits [0-4]: audioObjectType  Bits [5-8]: samplingFrequencyIndex
// This is authoritative over codecpar.sample_rate which may be an SFI index.
private func srFromASC(_ data: UnsafePointer<UInt8>, _ size: Int32) -> Int32? {
    guard size >= 2 else { return nil }
    let sfi = Int(((data[0] & 0x07) << 1) | (data[1] >> 7))
    if sfi == 0x0f {                        // explicit 24-bit frequency
        guard size >= 5 else { return nil }
        let hz = (Int32(data[1] & 0x7f) << 17) | (Int32(data[2]) << 9) |
                 (Int32(data[3]) << 1)          |  Int32(data[4] >> 7)
        return hz > 0 ? hz : nil
    }
    return sfi < aacSFRates.count ? aacSFRates[sfi] : nil
}

final class FFmpegAudioDecoder {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    let outputSampleRate: Int32
    let outputChannels: Int32
    private var decodedFrames = 0
    private var failedPackets = 0
    private var failedReceives = 0

    init?(stream: UnsafeMutablePointer<AVStream>, sampleRate: Int32 = 44100, channels: Int32 = 2) {
        let codecpar = stream.pointee.codecpar.pointee

        // Resolve these early — required before any `return nil` (Swift DI rule).
        // Prefer sample rate from AudioSpecificConfig extradata (authoritative);
        // codecpar.sample_rate may be an SFI index rather than Hz.
        let effectiveSR: Int32
        if let src = codecpar.extradata, codecpar.extradata_size >= 2,
           let ascHz = srFromASC(src, codecpar.extradata_size) {
            effectiveSR = ascHz
        } else {
            effectiveSR = resolveHz(codecpar.sample_rate, fallback: sampleRate)
        }
        let effectiveCh = codecpar.ch_layout.nb_channels > 0
            ? codecpar.ch_layout.nb_channels
            : (channels > 0 ? channels : 2)
        self.outputSampleRate = effectiveSR
        self.outputChannels   = effectiveCh

        // Standard FFmpeg init (per KSPlayer):
        // 1. alloc with nil — no codec priv_data allocated yet, so
        //    avcodec_parameters_to_context won't trigger the coded_side_data
        //    migration that leaves a sentinel in ctx->extradata.
        // 2. avcodec_parameters_to_context copies extradata directly.
        // 3. find decoder AFTER parameters_to_context.
        // 4. fix sample_rate (codecpar may carry an SFI index, not Hz).
        // 5. avcodec_open2.
        guard let ctx = avcodec_alloc_context3(nil) else { return nil }
        self.codecCtx = ctx

        guard avcodec_parameters_to_context(ctx, stream.pointee.codecpar) == 0 else {
            logger.error("avcodec_parameters_to_context FAILED")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        guard let codec = avcodec_find_decoder(ctx.pointee.codec_id) else {
            logger.error("codec not found")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        // Do NOT touch any AVCodecContext fields after avcodec_parameters_to_context.
        // The Swift bridge's AVCodecContext layout may differ from the actual FFmpeg
        // 8.x binary — writing fields at wrong offsets corrupts pointers and crashes
        // avcodec_open2. The codec reads all config (sample_rate, extradata, etc.)
        // from coded_side_data set up by avcodec_parameters_to_context.

        logger.info("opening codec (codecpar sr=\(codecpar.sample_rate) ch=\(codecpar.ch_layout.nb_channels) extradata=\(codecpar.extradata_size)B)")
        guard avcodec_open2(ctx, codec, nil) == 0 else {
            logger.error("avcodec_open2 FAILED")
            avcodec_free_context(&self.codecCtx)
            return nil
        }
        logger.info("codec opened OK, output: \(self.outputSampleRate)Hz \(self.outputChannels)ch")
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> PCMFrame? {
        guard let ctx = codecCtx else { return nil }
        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet == 0 else {
            failedPackets += 1
            if failedPackets <= 3 {
                logger.error("send_packet FAILED ret=\(sendRet) (#\(self.failedPackets))")
            }
            return nil
        }

        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }

        let recvRet = avcodec_receive_frame(ctx, frame)
        guard recvRet == 0, let f = frame else {
            failedReceives += 1
            if failedReceives <= 5 || failedReceives % 50 == 0 {
                logger.error("receive_frame[\(self.failedReceives)] ret=\(recvRet)")
            }
            return nil
        }

        if decodedFrames == 0 {
            logger.info("first frame: sr=\(f.pointee.sample_rate) nb=\(f.pointee.nb_samples) fmt=\(f.pointee.format) ch=\(f.pointee.ch_layout.nb_channels)")
        }
        decodedFrames += 1
        let pts = Double(f.pointee.pts)
            * Double(f.pointee.time_base.num)
            / Double(max(f.pointee.time_base.den, 1))
        return resample(frame: f, pts: pts)
    }

    private func resample(frame: UnsafeMutablePointer<AVFrame>, pts: Double) -> PCMFrame? {
        // Prefer frame.sample_rate; fall back to outputSampleRate if codec didn't fill it.
        let inSampleRate = frame.pointee.sample_rate > 0 ? frame.pointee.sample_rate : outputSampleRate
        let inFormat     = AVSampleFormat(rawValue: frame.pointee.format)
        let nbSamples    = Int(frame.pointee.nb_samples)
        guard nbSamples > 0, inSampleRate > 0 else {
            logger.info("resample skip: sr=\(frame.pointee.sample_rate) nb=\(frame.pointee.nb_samples) fmt=\(frame.pointee.format)")
            return nil
        }

        if swrCtx == nil {
            // FFmpeg 8.x AAC decoder may not fill frame->ch_layout; fall back to
            // the channel count derived from codecpar/extradata at init time.
            var inLayout = AVChannelLayout()
            if frame.pointee.ch_layout.nb_channels > 0 {
                inLayout = frame.pointee.ch_layout
            } else {
                av_channel_layout_default(&inLayout, outputChannels)
            }
            var outLayout = AVChannelLayout()
            av_channel_layout_default(&outLayout, outputChannels)
            swr_alloc_set_opts2(&swrCtx,
                                &outLayout, AV_SAMPLE_FMT_FLT, outputSampleRate,
                                &inLayout,  inFormat,           inSampleRate,
                                0, nil)
            guard swrCtx != nil, swr_init(swrCtx) == 0 else {
                logger.error("swr_init FAILED")
                if swrCtx != nil { swr_free(&swrCtx) }  // don't leave half-init context
                return nil
            }
            logger.info("swr init: \(inSampleRate)→\(self.outputSampleRate)Hz \(inLayout.nb_channels)ch→\(self.outputChannels)ch")
        }

        let outSamples = swr_get_out_samples(swrCtx, Int32(nbSamples))
        let outSize    = Int(outSamples) * Int(outputChannels) * MemoryLayout<Float>.size
        var outData    = Data(count: outSize)

        let converted = outData.withUnsafeMutableBytes { outBuf -> Int in
            guard let outPtr = outBuf.baseAddress else { return 0 }
            var outPtrs: [UnsafeMutablePointer<UInt8>?] = [outPtr.assumingMemoryBound(to: UInt8.self)]
            var inPtrs: [UnsafePointer<UInt8>?] = [
                UnsafePointer(frame.pointee.data.0),
                UnsafePointer(frame.pointee.data.1),
                UnsafePointer(frame.pointee.data.2),
            ]
            return Int(swr_convert(swrCtx, &outPtrs, outSamples, &inPtrs, Int32(nbSamples)))
        }

        guard converted > 0 else { return nil }
        outData.count = converted * Int(outputChannels) * MemoryLayout<Float>.size
        return PCMFrame(data: outData, pts: pts, sampleCount: converted)
    }

    func flush() {
        if let ctx = codecCtx { avcodec_flush_buffers(ctx) }
        if let swr = swrCtx   { swr_convert(swr, nil, 0, nil, 0) }
    }

    deinit {
        avcodec_free_context(&codecCtx)
        if swrCtx != nil { swr_free(&swrCtx) }
        logger.info("deinit, decoded \(self.decodedFrames) frames")
    }
}
