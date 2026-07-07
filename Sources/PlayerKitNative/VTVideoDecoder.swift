import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CFFmpeg

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
    private var needsParamSetInit: Bool
    private var pendingSPS: [UInt8]?
    private var pendingPPS: [UInt8]?
    private var pendingVPS: [UInt8]?
    private var initFailed = false

    // MARK: - init

    init?(stream: UnsafeMutablePointer<AVStream>) {
        let cp = stream.pointee.codecpar.pointee
        self.isH264 = (cp.codec_id == AV_CODEC_ID_H264)

        // Try to build format description from parameter sets in codecpar.
        // FFmpeg 8.x may store them in coded_side_data with a sentinel in extradata.
        if let desc = VTVideoDecoder.formatDescFromCodecpar(cp, isH264: isH264),
           let s    = VTVideoDecoder.makeSession(formatDesc: desc) {
            self.formatDesc        = desc
            self.session           = s
            let dims               = CMVideoFormatDescriptionGetDimensions(desc)
            self.width             = Int(dims.width)
            self.height            = Int(dims.height)
            self.needsParamSetInit = false
            NSLog("[VTVideoDecoder] init OK from codecpar: \(self.width)x\(self.height)")
        } else {
            // Will initialise from in-band parameter sets (first IDR packet)
            self.width             = Int(cp.width)
            self.height            = Int(cp.height)
            self.needsParamSetInit = true
            NSLog("[VTVideoDecoder] \(isH264 ? "H.264" : "HEVC") — waiting for in-band param sets")
        }
    }

    // MARK: - decode

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> CVPixelBuffer? {
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

        return vtDecode(lpData: lpData, session: session, formatDesc: formatDesc)
    }

    // MARK: - flush / deinit

    func flush() {
        if let session { VTDecompressionSessionFinishDelayedFrames(session) }
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
        NSLog("[VTVideoDecoder] deinit")
    }

    // MARK: - Private helpers

    private func initFromPendingParams() {
        let desc: CMVideoFormatDescription?
        if isH264, let sps = pendingSPS, let pps = pendingPPS {
            desc = VTVideoDecoder.makeH264FormatDesc(sps: sps, pps: pps)
        } else if let vps = pendingVPS, let sps = pendingSPS, let pps = pendingPPS {
            desc = VTVideoDecoder.makeHEVCFormatDesc(vps: vps, sps: sps, pps: pps)
        } else { desc = nil }

        guard let d = desc, let s = VTVideoDecoder.makeSession(formatDesc: d) else {
            NSLog("[VTVideoDecoder] failed to init from in-band params")
            initFailed = true
            return
        }
        self.formatDesc = d
        self.session    = s
        let dims = CMVideoFormatDescriptionGetDimensions(d)
        self.width  = Int(dims.width)
        self.height = Int(dims.height)
        self.needsParamSetInit = false
        NSLog("[VTVideoDecoder] init OK from in-band params: \(self.width)x\(self.height)")
    }

    private func vtDecode(lpData: Data,
                          session: VTDecompressionSession,
                          formatDesc: CMVideoFormatDescription) -> CVPixelBuffer? {
        var blockBuf: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: lpData.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: lpData.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuf
        ) == kCMBlockBufferNoErr, let bb = blockBuf else { return nil }

        var ok = false
        lpData.withUnsafeBytes { raw in
            ok = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: lpData.count
            ) == kCMBlockBufferNoErr
        }
        guard ok else { return nil }

        var timing    = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleLen = lpData.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleLen,
            sampleBufferOut: &sb
        ) == noErr, let sb else { return nil }

        var result: CVPixelBuffer?
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { _, _, buf, _, _ in
            result = buf
        }
        return result
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
                NSLog("[VTVideoDecoder] extradata \(cp.extradata_size)B from codecpar")
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
            NSLog("[VTVideoDecoder] extradata \(sd.size)B from coded_side_data[\(i)]")
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
        if status != noErr { NSLog("[VTVideoDecoder] H264FormatDesc failed: \(status)") }
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
        if status != noErr { NSLog("[VTVideoDecoder] HEVCFormatDesc failed: \(status)") }
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

    static func makeSession(formatDesc: CMVideoFormatDescription) -> VTDecompressionSession? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: formatDesc,
            decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        if status != noErr { NSLog("[VTVideoDecoder] session create failed: \(status)") }
        return status == noErr ? session : nil
    }
}

extension VTVideoDecoder: VideoDecoding {}
