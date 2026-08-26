import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox
import PlayerKit
import CFFmpeg
import os

private let logger = Logger(subsystem: "io.reflux.PlayerKit", category: "decoder.video")

// MARK: - VTVideoDecoder
// Hardware video decoder using VideoToolbox for H.264 and HEVC.
// Reads codec parameters from FFmpeg 8.x's coded_side_data API when
// the legacy codecpar.extradata contains a sentinel (low-address) value.

final class VTVideoDecoder {
    private(set) var width:  Int = 0
    private(set) var height: Int = 0
    let isHardware = true

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private let isH264: Bool
    let is10Bit: Bool
    private let needsHDRTag: Bool
    private let colorParams: VideoColorParams
    private var needsParamSetInit: Bool
    private var pendingSPS: [UInt8]?
    private var pendingPPS: [UInt8]?
    private var pendingVPS: [UInt8]?
    private var initFailed = false
    private var totalAttempts = 0
    private var failedAttempts = 0
    // Set by vtDecode when VT returns a non-zero status (real decode error).
    private var lastVTError = false
    /// Transient error recovery: when VT returns a session-level error
    /// (kVTInvalidSessionErr etc.), we recreate the session instead of
    /// counting it toward the permanent fallback heuristic. These errors
    /// happen during PiP/background transitions and are recoverable.
    private var transientErrorCount = 0
    private var maxTransientRetries = 3

    private let streamStartTime: Int64
    private let streamTimeBase: AVRational

    // Per-NAL-type success/failure counts, split IDR vs non-IDR. Some BD
    // H.264 streams make VT fail the majority of non-IDR (P/B) NALs with
    // kVTVideoDecoderBadDataErr while every IDR decodes fine; keyframes are
    // a small always-succeeding minority (~1 per GOP) that permanently
    // dilutes the aggregate totalAttempts/failedAttempts ratio below,
    // masking the problem from the whole-stream fallback heuristic. Feeds
    // needsSoftwareFallback below.
    private var idrSuccessCount = 0
    private var idrFailCount = 0
    private var nonIDRSuccessCount = 0
    private var nonIDRFailCount = 0

    /// True when VT decoder is genuinely broken (real errors, not just idle packets).
    /// Only counts frames where VT returned a non-zero error status. Packets that
    /// produce no output because they contain only non-decodable NALs (AUD, SEI etc.)
    /// are NOT counted as failures — VT correctly ignores those.
    var needsSoftwareFallback: Bool {
        if initFailed { return true }
        // Must have meaningful sample size AND >90% real error rate.
        if totalAttempts >= 200 && Double(failedAttempts) / Double(totalAttempts) > 0.9 {
            return true
        }
        // Non-keyframe-specific fallback: some BD H.264 streams hit VT
        // returning kVTVideoDecoderBadDataErr on the majority of non-IDR
        // NALs while every IDR decodes fine (observed on-device: ~75-80%
        // sustained failure rate on P/B frames, 0% on keyframes). Keyframes
        // are a small, always-succeeding minority of attempts (~1 per GOP),
        // so they permanently dilute the aggregate ratio above well under
        // the 90% cutoff — the whole-stream heuristic never fires even
        // after minutes of persistent near-frozen playback. This mirrors
        // the same >90%-of-a-meaningful-sample shape, scoped to the subset
        // that's actually failing instead of the diluted aggregate.
        let nonIDRTotal = nonIDRSuccessCount + nonIDRFailCount
        if nonIDRTotal >= 100, Double(nonIDRFailCount) / Double(nonIDRTotal) > 0.5 {
            return true
        }
        return false
    }

    // MARK: - init

    /// - Parameter prefer10Bit: When true, requests 10-bit VT output for HDR renderers
    ///   (EDRRenderer). MetalRenderer passes false and uses fake-PQ 8-bit + CIToneCurve.
    init?(stream: UnsafeMutablePointer<AVStream>, prefer10Bit: Bool = false,
          colorParams: VideoColorParams = VideoColorParams()) {
        let cp = stream.pointee.codecpar.pointee
        self.streamStartTime = stream.pointee.start_time
        self.streamTimeBase  = stream.pointee.time_base
        // VideoToolbox only decodes H.264 and HEVC. Without this guard, every
        // other codec (RealVideo rv40, VP8, old MPEG-4 profiles, WMV...) falls
        // through the `isH264 ? H.264 : HEVC` binary below and gets silently
        // treated as HEVC: init "succeeds" (returns non-nil), but the in-band
        // parameter-set scan below expects HEVC NAL unit framing that the
        // actual bitstream never has, so `decode(packet:)` returns nil forever
        // and zero frames ever reach the renderer — without ever tripping
        // `needsSoftwareFallback` (VT is never actually invoked, so there are
        // no counted errors) or the `NativeBackend` `.vtHW` init-failure
        // fallback to `FFmpegVideoDecoder` (this initializer never returns nil).
        guard cp.codec_id == AV_CODEC_ID_H264 || cp.codec_id == AV_CODEC_ID_HEVC else {
            logger.info("codec \(String(cString: avcodec_get_name(cp.codec_id))) unsupported by VideoToolbox — deferring to FFmpeg software decode")
            return nil
        }
        self.isH264 = (cp.codec_id == AV_CODEC_ID_H264)
        // MKV containers often leave bits_per_raw_sample = 0 even for HEVC Main10.
        // Fall back to profile check: AV_PROFILE_HEVC_MAIN_10 = 2, REXT = 4.
        let isHEVC = cp.codec_id == AV_CODEC_ID_HEVC
        let is10BitByProfile = isHEVC && (cp.profile == AV_PROFILE_HEVC_MAIN_10 ||
                                          cp.profile == AV_PROFILE_HEVC_REXT)
        let isHDR10 = !isH264 && (cp.bits_per_raw_sample >= 10 || is10BitByProfile)
        // 10-bit output: required by EDRRenderer so CI color management sees real PQ
        // values, not 8-bit SDR-range values falsely tagged as PQ (which appear black).
        // MetalRenderer uses 8-bit + needsHDRTag + CIToneCurve instead.
        self.is10Bit     = prefer10Bit && isHDR10
        self.needsHDRTag = !self.is10Bit && isHDR10
        self.colorParams = colorParams

        // Try to build format description from parameter sets in codecpar.
        // FFmpeg 8.x may store them in coded_side_data with a sentinel in extradata.
        if let desc = VTVideoDecoder.formatDescFromCodecpar(cp, isH264: isH264),
           let s    = VTVideoDecoder.makeSession(formatDesc: desc, is10Bit: is10Bit) {
            self.formatDesc        = desc
            self.session           = s
            let dims               = CMVideoFormatDescriptionGetDimensions(desc)
            self.width             = Int(dims.width)
            self.height            = Int(dims.height)
            self.needsParamSetInit = false
            logger.info("init OK from codecpar: \(self.width)x\(self.height)")
        } else {
            // Will initialise from in-band parameter sets (first IDR packet)
            self.width             = Int(cp.width)
            self.height            = Int(cp.height)
            self.needsParamSetInit = true
            logger.info("\(self.isH264 ? "H.264" : "HEVC") — waiting for in-band param sets")
        }
    }

    // MARK: - decode

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> DecodedVideoFrame? {
        guard let dataPtr = packet.pointee.data else { return nil }
        let dataSize = Int(packet.pointee.size)
        guard dataSize > 4, !initFailed else { return nil }

        let isAnnexB = dataPtr[0] == 0 && dataPtr[1] == 0 &&
                       dataPtr[2] == 0 && dataPtr[3] == 1

        // ── Phase 1: collect in-band parameter sets if not yet initialised ──
        if needsParamSetInit {
            if isAnnexB {
                let raw = Array(UnsafeBufferPointer(start: dataPtr, count: dataSize))
                for nalu in VTVideoDecoder.splitAnnexB(raw) where !nalu.isEmpty {
                    if isH264 {
                        switch Int(nalu[0] & 0x1F) {
                        case 7: pendingSPS = nalu
                        case 8: pendingPPS = nalu
                        default: break
                        }
                    } else {
                        switch Int((nalu[0] >> 1) & 0x3F) {
                        case 32: pendingVPS = nalu
                        case 33: pendingSPS = nalu
                        case 34: pendingPPS = nalu
                        default: break
                        }
                    }
                }
            }
            let ready = isH264
                ? (pendingSPS != nil && pendingPPS != nil)
                : (pendingVPS != nil && pendingSPS != nil && pendingPPS != nil)
            if ready { initFromPendingParams() }
            if needsParamSetInit { return nil }
        }

        guard let session, let formatDesc else { return nil }

        // ── Phase 2: convert to length-prefixed AVCC/HVCC and decode ────────
        let lpData: Data
        if isAnnexB {
            let raw     = Array(UnsafeBufferPointer(start: dataPtr, count: dataSize))
            let nalUnits = VTVideoDecoder.splitAnnexB(raw).filter { nalu -> Bool in
                guard !nalu.isEmpty else { return false }
                if isH264 { let t = Int(nalu[0] & 0x1F);       return t != 7 && t != 8 }
                else       { let t = Int((nalu[0] >> 1) & 0x3F); return t != 32 && t != 33 && t != 34 }
            }
            guard !nalUnits.isEmpty else { return nil }
            var data = Data(capacity: dataSize)
            for nalu in nalUnits {
                var len = UInt32(nalu.count).bigEndian
                withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
                data.append(contentsOf: nalu)
            }
            lpData = data
        } else {
            lpData = Data(bytes: dataPtr, count: dataSize)
        }
        guard !lpData.isEmpty else { return nil }

        // Classify whether this packet's NAL stream contains an IDR slice
        // (type 5) — feeds the idr/nonIDR success/failure counters that
        // needsSoftwareFallback uses above.
        var isIDR = false
        if isAnnexB {
            let raw = Array(UnsafeBufferPointer(start: dataPtr, count: dataSize))
            for nalu in VTVideoDecoder.splitAnnexB(raw) where !nalu.isEmpty {
                if Int(nalu[0] & 0x1F) == 5 { isIDR = true; break }
            }
        }

        // Build CMSampleTimingInfo from the packet's PTS/DTS so VT can
        // reorder B-frames correctly. Without this (previously all-zero),
        // VT emits frames in decode order, and the caller has no way to
        // recover display-order PTS → ~1/3 of frames are mislabelled,
        // producing visible judder on B-frame-heavy BD content.
        let noPTS = Int64(bitPattern: 0x8000000000000000)
        let timescale = Int32(max(streamTimeBase.den, 1))
        let ptsCMTime: CMTime = packet.pointee.pts != noPTS
            ? CMTime(value: CMTimeValue(packet.pointee.pts), timescale: timescale)
            : .invalid
        let dtsCMTime: CMTime = packet.pointee.dts != noPTS
            ? CMTime(value: CMTimeValue(packet.pointee.dts), timescale: timescale)
            : .invalid
        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: ptsCMTime,
            decodeTimeStamp: dtsCMTime
        )

        let (pbOpt, outPTS) = vtDecode(lpData: lpData, session: session,
                                       formatDesc: formatDesc, timing: timing)
        if pbOpt != nil {
            if isIDR { idrSuccessCount += 1 } else { nonIDRSuccessCount += 1 }
        } else {
            if isIDR { idrFailCount += 1 } else { nonIDRFailCount += 1 }
        }
        guard let pb = pbOpt else {
            // VT decode failure path — still count attempts for fallback heuristics.
            if !needsParamSetInit {
                totalAttempts += 1
                if lastVTError { failedAttempts += 1 }
            }
            return nil
        }
        if !needsParamSetInit {
            totalAttempts += 1
            if lastVTError { failedAttempts += 1 }
        }
        // VT strips Dolby Vision RPU side data, so per-frame metadata is empty.
        // DoVi streams forced to FFmpeg SW in NativeBackend carry per-frame DM.
        // Convert VT's output PTS (display-order, post-reorder) to the same
        // t=0-relative timeline as the caller's ptsFromPacket() by subtracting
        // stream start_time — without this, BD streams with ~600s start_time
        // would put decoderPts far ahead of rawPTS, failing the sanity bound.
        var framePTS: Double? = nil
        if outPTS.isValid {
            var ptsSecs = Double(outPTS.value) / Double(outPTS.timescale)
            if streamStartTime != noPTS {
                let startOffset = Double(streamStartTime) * Double(streamTimeBase.num) / Double(max(streamTimeBase.den, 1))
                ptsSecs -= startOffset
            }
            framePTS = ptsSecs
        }
        return DecodedVideoFrame(pixelBuffer: pb, metadata: FrameMetadata(), pts: framePTS)
    }

    // MARK: - flush / deinit

    func flush() {
        if let session { VTDecompressionSessionFinishDelayedFrames(session) }
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
        logger.info("deinit")
    }

    // MARK: - Private helpers

    private func initFromPendingParams() {
        let desc: CMVideoFormatDescription?
        if isH264, let sps = pendingSPS, let pps = pendingPPS {
            desc = VTVideoDecoder.makeH264FormatDesc(sps: sps, pps: pps)
        } else if let vps = pendingVPS, let sps = pendingSPS, let pps = pendingPPS {
            desc = VTVideoDecoder.makeHEVCFormatDesc(vps: vps, sps: sps, pps: pps)
        } else { desc = nil }

        guard let d = desc, let s = VTVideoDecoder.makeSession(formatDesc: d, is10Bit: is10Bit) else {
            logger.error("failed to init from in-band params")
            initFailed = true
            return
        }
        self.formatDesc = d
        self.session    = s
        let dims = CMVideoFormatDescriptionGetDimensions(d)
        self.width  = Int(dims.width)
        self.height = Int(dims.height)
        self.needsParamSetInit = false
        logger.info("init OK from in-band params: \(self.width)x\(self.height)")
    }

    private func vtDecode(lpData: Data,
                          session: VTDecompressionSession,
                          formatDesc: CMVideoFormatDescription,
                          timing: CMSampleTimingInfo) -> (CVPixelBuffer?, CMTime) {
        var blockBuf: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: lpData.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: lpData.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuf
        ) == kCMBlockBufferNoErr, let bb = blockBuf else { return (nil, .invalid) }

        var ok = false
        lpData.withUnsafeBytes { raw in
            ok = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: lpData.count
            ) == kCMBlockBufferNoErr
        }
        guard ok else { return (nil, .invalid) }

        var timingInfo = timing
        var sampleLen = lpData.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleLen,
            sampleBufferOut: &sb
        ) == noErr, let sb else { return (nil, .invalid) }

        var result: CVPixelBuffer?
        var decodeStatus: OSStatus = noErr
        var outputPTS: CMTime = .invalid
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, buf, pts, _ in
            decodeStatus = status
            result = buf
            outputPTS = pts
        }

        // Distinguish transient session errors (recoverable: PiP/background
        // transitions invalidate the VT session) from permanent data errors
        // (codec incompatibility, corrupt bitstream). Transient errors should
        // trigger session recreation, not count toward fallback heuristic.
        if decodeStatus != noErr {
            if Self.isTransientError(decodeStatus) {
                logger.warning("VT transient error \(decodeStatus) — recreating session")
                transientErrorCount += 1
                if transientErrorCount <= maxTransientRetries {
                    recreateSession()
                    // Retry decode with the new session
                    if let newSession = self.session {
                        VTDecompressionSessionDecodeFrame(newSession, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status2, _, buf2, pts2, _ in
                            decodeStatus = status2
                            result = buf2
                            outputPTS = pts2
                        }
                        if decodeStatus == noErr {
                            transientErrorCount = 0
                            lastVTError = false
                        }
                    }
                }
                // Transient errors don't count toward fallback heuristic
                lastVTError = false
            } else {
                lastVTError = true
            }
        } else {
            lastVTError = false
            transientErrorCount = 0
        }

        // Tag HEVC Main 10 output with BT.2020/PQ colour metadata only when the
        // stream is actually HDR (PQ or HLG). 10-bit SDR streams (HEVC Main 10
        // with no color_trc tag) must NOT receive BT.2020/PQ attachments, or
        // CIImage(cvPixelBuffer:) will apply a PQ→sRGB transfer that shifts
        // SDR BT.709 colours toward red.
        if let buf = result, colorParams.transfer == .pq || colorParams.transfer == .hlg {
            CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
        return (result, outputPTS)
    }

    /// Check if a VT error status is transient (recoverable by recreating session).
    /// These happen during PiP/background transitions when the system invalidates
    /// the VT session — they're NOT permanent decoder failures.
    private static func isTransientError(_ status: OSStatus) -> Bool {
        switch status {
        case kVTInvalidSessionErr,              // -12903: session invalidated (PiP/background)
             kVTVideoDecoderNotAvailableNowErr,  // -12913: HW decoder temporarily unavailable
             kVTAllocationFailedErr:             // -12904: transient resource pressure
            return true
        default:
            return false
        }
    }

    /// Recreate the VTDecompressionSession using the existing formatDesc.
    /// Called when a transient error invalidates the session (PiP/background).
    private func recreateSession() {
        guard let desc = formatDesc else { return }
        if let oldSession = session {
            VTDecompressionSessionInvalidate(oldSession)
        }
        if let newSession = VTVideoDecoder.makeSession(formatDesc: desc, is10Bit: is10Bit) {
            session = newSession
            logger.info("VT session recreated after transient error")
        } else {
            logger.error("VT session recreation failed — marking as failed")
            // If recreation fails, the session is truly broken
            session = nil
        }
    }

    // MARK: - Codec-parameter extraction (FFmpeg 8.x aware)

    /// Try extradata first; if it's a sentinel fall back to coded_side_data.
    static func formatDescFromCodecpar(_ cp: AVCodecParameters, isH264: Bool) -> CMVideoFormatDescription? {
        if let bytes = realExtradata(cp) {
            return isH264
                ? parseAVCC(bytes).flatMap { makeH264FormatDesc(sps: $0.sps, pps: $0.pps) }
                : parseHVCC(bytes).flatMap { makeHEVCFormatDesc(vps: $0.vps[0], sps: $0.sps[0], pps: $0.pps[0]) }
        }
        return nil
    }

    /// Return extradata bytes only if the pointer is a real heap address.
    /// FFmpeg 8.x may place a low-address sentinel when data lives in coded_side_data.
    static func realExtradata(_ cp: AVCodecParameters) -> [UInt8]? {
        // Check codecpar.extradata
        if let ext = cp.extradata {
            let addr = UInt(bitPattern: ext)
            if addr >= 0x100000000, cp.extradata_size >= 4 {
                logger.info("extradata \(cp.extradata_size)B from codecpar")
                return Array(UnsafeBufferPointer(start: ext, count: Int(cp.extradata_size)))
            }
        }
        // Sentinel detected or no extradata — check coded_side_data
        let nbSD = Int(cp.nb_coded_side_data)
        guard nbSD > 0, let sdPtr = cp.coded_side_data,
              UInt(bitPattern: sdPtr) >= 0x100000000 else { return nil }
        for i in 0..<nbSD {
            let sd = sdPtr[i]
            guard sd.type == AV_PKT_DATA_NEW_EXTRADATA,
                  let data = sd.data, sd.size >= 4,
                  UInt(bitPattern: data) >= 0x100000000 else { continue }
            logger.info("extradata \(sd.size)B from coded_side_data[\(i)]")
            return Array(UnsafeBufferPointer(start: data, count: Int(sd.size)))
        }
        return nil
    }

    // MARK: - H.264 helpers

    struct H264PS { let sps: [UInt8]; let pps: [UInt8] }
    static func parseAVCC(_ bytes: [UInt8]) -> H264PS? {
        guard bytes.count >= 8, bytes[0] == 0x01 else { return nil }
        var off = 5
        guard off < bytes.count else { return nil }
        let numSPS = Int(bytes[off] & 0x1F); off += 1
        var sps: [UInt8]?
        for _ in 0..<numSPS {
            guard off + 2 <= bytes.count else { return nil }
            let len = (Int(bytes[off]) << 8) | Int(bytes[off+1]); off += 2
            guard len > 0, off + len <= bytes.count else { return nil }
            sps = Array(bytes[off..<(off+len)]); off += len
        }
        guard let sps, off < bytes.count else { return nil }
        let numPPS = Int(bytes[off]); off += 1
        var pps: [UInt8]?
        for _ in 0..<numPPS {
            guard off + 2 <= bytes.count else { return nil }
            let len = (Int(bytes[off]) << 8) | Int(bytes[off+1]); off += 2
            guard len > 0, off + len <= bytes.count else { return nil }
            pps = Array(bytes[off..<(off+len)]); off += len
        }
        guard let pps else { return nil }
        return H264PS(sps: sps, pps: pps)
    }

    static func makeH264FormatDesc(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var s = sps, p = pps, desc: CMVideoFormatDescription?
        let status: OSStatus = s.withUnsafeBufferPointer { spsBuf in
            p.withUnsafeBufferPointer { ppsBuf in
                guard let sb = spsBuf.baseAddress, let pb = ppsBuf.baseAddress else { return -1 }
                var ptrs: [UnsafePointer<UInt8>] = [sb, pb]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        if status != noErr { logger.error("H264FormatDesc failed: \(status)") }
        return status == noErr ? desc : nil
    }

    // MARK: - HEVC helpers

    struct HEVCParameterSets { var vps: [[UInt8]]; var sps: [[UInt8]]; var pps: [[UInt8]] }
    static func parseHVCC(_ bytes: [UInt8]) -> HEVCParameterSets? {
        guard bytes.count > 22, bytes[0] == 0x01 else { return nil }
        let numArrays = Int(bytes[22]); var off = 23
        var result = HEVCParameterSets(vps: [], sps: [], pps: [])
        for _ in 0..<numArrays {
            guard off + 3 <= bytes.count else { return nil }
            let nalType  = Int(bytes[off] & 0x3F)
            let numNalus = (Int(bytes[off+1]) << 8) | Int(bytes[off+2]); off += 3
            for _ in 0..<numNalus {
                guard off + 2 <= bytes.count else { return nil }
                let len = (Int(bytes[off]) << 8) | Int(bytes[off+1]); off += 2
                guard len > 0, off + len <= bytes.count else { return nil }
                let nalu = Array(bytes[off..<(off+len)]); off += len
                switch nalType { case 32: result.vps.append(nalu)
                                 case 33: result.sps.append(nalu)
                                 case 34: result.pps.append(nalu)
                                 default: break }
            }
        }
        guard !result.vps.isEmpty, !result.sps.isEmpty, !result.pps.isEmpty else { return nil }
        return result
    }

    static func makeHEVCFormatDesc(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var v = vps, s = sps, p = pps, desc: CMVideoFormatDescription?
        let status: OSStatus = v.withUnsafeBufferPointer { vBuf in
            s.withUnsafeBufferPointer { sBuf in
                p.withUnsafeBufferPointer { pBuf in
                    guard let vb = vBuf.baseAddress, let sb = sBuf.baseAddress,
                          let pb = pBuf.baseAddress else { return -1 }
                    var ptrs: [UnsafePointer<UInt8>] = [vb, sb, pb]
                    var sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
                }
            }
        }
        if status != noErr { logger.error("HEVCFormatDesc failed: \(status)") }
        return status == noErr ? desc : nil
    }

    // MARK: - Shared

    static func splitAnnexB(_ bytes: [UInt8]) -> [[UInt8]] {
        var nalUnits: [[UInt8]] = []
        var i = 0, start = -1
        while i < bytes.count {
            let is4 = i+3 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==0 && bytes[i+3]==1
            let is3 = !is4 && i+2 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==1
            if is4 || is3 {
                if start >= 0 { nalUnits.append(Array(bytes[start..<i])) }
                i += is4 ? 4 : 3; start = i
            } else { i += 1 }
        }
        if start >= 0, start < bytes.count { nalUnits.append(Array(bytes[start...])) }
        return nalUnits
    }

    /// Converts Annex-B byte stream to AVCC length-prefixed format.
    /// Each NAL unit gets a 4-byte big-endian length prefix.
    static func annexBToLengthPrefixed(_ bytes: [UInt8]) -> Data {
        var result = Data()
        for nal in splitAnnexB(bytes) {
            var length = UInt32(nal.count).bigEndian
            result.append(contentsOf: withUnsafeBytes(of: &length) { Array($0) })
            result.append(contentsOf: nal)
        }
        return result
    }

    /// Create a VTDecompressionSession. When `is10Bit` is true, requests 10-bit
    /// output from the hardware decoder (for HEVC Main 10 HDR content). Falls back
    /// to 8-bit if the hardware rejects 10-bit (older devices / Intel Macs).
    static func makeSession(formatDesc: CMVideoFormatDescription, is10Bit: Bool = false) -> VTDecompressionSession? {
        let pixelFormats: [OSType] = is10Bit
            ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]

        for (i, fmt) in pixelFormats.enumerated() {
            if i > 0 { logger.info("retrying with 8-bit pixel format") }
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: fmt,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: formatDesc,
                decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session)
            if status == noErr {
                if i > 0 { logger.info("8-bit fallback OK") }
                return session
            }
            logger.error("session create failed (fmt=\(fmt)): \(status)")
        }
        return nil
    }
}

extension VTVideoDecoder: VideoDecoding {}
