import Foundation

/// Dolby Vision configuration record carried in a Blu-ray M2TS / MPEG-TS
/// stream, extracted from the video ES's PMT `registration_descriptor`
/// (format_identifier 'DOVI'). The 24-byte payload is the same dvcC bit
/// layout mp4 uses; ffmpeg's mpegts demuxer never surfaces it as codecpar
/// side data, so disc playback needs this explicit extraction step.
public struct DiscDoviConfig: Equatable {
    public var versionMajor: UInt8
    public var versionMinor: UInt8
    /// DV profile: 5 (IPT), 7 (BL+EL dual layer), 8 (compat).
    public var profile: UInt8
    public var level: UInt8
    public var rpuPresent: Bool
    public var elPresent: Bool
    public var blPresent: Bool
    /// bl_signal_compatibility_id — 2 means the BL is HDR10-compatible.
    public var blSignalCompatibilityId: UInt8
}

/// Scans a raw TS (188-byte packets) or M2TS (192-byte packets, UHD
/// Blu-ray) byte stream for the Dolby Vision config in the PMT.
///
/// Parsing is deliberately defensive: every access is bounds-checked and
/// malformed input yields nil rather than a crash — this runs against
/// network-fed bytes.
public enum DiscDoviProbe {

    /// Returns nil when the stream contains no HEVC ES with a DOVI
    /// registration descriptor.
    public static func extractDoviConfig(from data: Data) -> DiscDoviConfig? {
        let pkts = packets(in: data)
        // BDMV M2TS has no PAT (playlist/clpi drives stream selection) — its
        // PMT sits at the fixed PID 0x0100. Generic TS: PAT names the PMT PID.
        // Fixed PID first: BDMV is the disc case this probe exists for, and
        // on generic TS parsePMT validates the table_id before trusting it.
        var pmtPids: [UInt16] = [0x0100]
        for tsPacket in pkts where isPUSI(tsPacket) && packetPID(tsPacket) == 0x0000 {
            if let pmtPid = parsePAT(packetPayload(tsPacket)), !pmtPids.contains(pmtPid) {
                pmtPids.append(pmtPid)
            }
        }
        for pmtPid in pmtPids {
            guard let pmtPacket = pkts.first(where: { isPUSI($0) && packetPID($0) == pmtPid }) else {
                continue
            }
            if let config = parsePMT(packetPayload(pmtPacket)) {
                return config
            }
        }
        return nil
    }

    // MARK: - Packet layer

    /// Splits the byte stream into TS packets, auto-detecting 192-byte
    /// M2TS (4-byte TP_extra_header prefix) vs 188-byte TS framing by
    /// which stride lines up more sync bytes.
    private static func packets(in data: Data) -> [Data] {
        let sync: UInt8 = 0x47
        let n = data.count

        func syncMatches(stride: Int) -> Int {
            var count = 0
            var i = stride == 192 ? 4 : 0
            guard i < n, data[data.startIndex + i] == sync else { return 0 }
            while i + 188 <= n {
                if data[data.startIndex + i] == sync { count += 1 }
                i += stride
            }
            return count
        }

        let stride: Int
        if syncMatches(stride: 192) > syncMatches(stride: 188) {
            stride = 192
        } else {
            stride = 188
        }

        var out: [Data] = []
        var i = stride == 192 ? 4 : 0
        while i + 188 <= n {
            let start = data.startIndex + i
            if data[start] == sync {
                out.append(data.subdata(in: start..<start + 188))
            }
            i += stride
        }
        return out
    }

    private static func isPUSI(_ pkt: Data) -> Bool {
        pkt.count >= 2 && (pkt[pkt.startIndex + 1] & 0x40) != 0
    }

    private static func packetPID(_ pkt: Data) -> UInt16 {
        let hi = UInt16(pkt[pkt.startIndex + 1] & 0x1F)
        let lo = UInt16(pkt[pkt.startIndex + 2])
        return (hi << 8) | lo
    }

    /// Payload after the 4-byte TS header (no adaptation field assumed;
    /// descriptor sections don't need AF-aware parsing when absent).
    private static func packetPayload(_ pkt: Data) -> Data {
        let s = pkt.startIndex
        guard pkt.count >= 5 else { return Data() }
        if pkt[s + 3] & 0x20 != 0 {
            // Adaptation field present — skip it.
            guard pkt.count >= 6 else { return Data() }
            let afLen = Int(pkt[s + 4])
            guard 5 + afLen < pkt.count else { return Data() }
            return pkt.subdata(in: s + 5 + afLen..<s + 188)
        }
        return pkt.subdata(in: s + 4..<s + 188)
    }

    private static func firstPUSIPacket(_ pid: UInt16, in data: Data) -> Data? {
        packets(in: data).first { isPUSI($0) && packetPID($0) == pid }
    }

    /// Human-readable diagnostic for on-device log forensics: what the
    /// probe saw in the stream head (packet layout, PAT result, PMT ES
    /// entries and their descriptor tags). Empty string when nothing
    /// parseable was found.
    public static func describe(from data: Data) -> String {
        let pkts = packets(in: data)
        guard !pkts.isEmpty else { return "no TS packets" }
        var lines: [String] = ["packets=\(pkts.count)"]
        var pmtPid: UInt16? = pkts.first(where: { isPUSI($0) && packetPID($0) == 0x0000 })
            .flatMap { parsePAT(packetPayload($0)) }
        if pmtPid == nil, pkts.contains(where: { packetPID($0) == 0x0100 }) {
            pmtPid = 0x0100
            lines.append("pat=absent(using fixed BDMV PID)")
        } else {
            lines.append("pat=\(pmtPid.map { String(format: "0x%04X", $0) } ?? "absent")")
        }
        if let pmtPid,
           let pmtPacket = pkts.first(where: { isPUSI($0) && packetPID($0) == pmtPid }) {
            lines.append(pmtDescription(packetPayload(pmtPacket)))
        } else {
            lines.append("pmt=not-found")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Section layer

    /// PAT section → the first program's PMT PID (program_number 0 is NIT).
    private static func parsePAT(_ payload: Data) -> UInt16? {
        guard let section = sectionBytes(from: payload) else { return nil }
        let s = section.startIndex
        guard section.count >= 12 else { return nil }
        let sectionLength = Int(section[s + 1] & 0x0F) << 8 | Int(section[s + 2])
        let end = min(s + 3 + sectionLength - 4, section.endIndex)  // strip CRC32
        var i = s + 8
        while i + 4 <= end {
            let programNumber = UInt16(section[i]) << 8 | UInt16(section[i + 1])
            let pid = (UInt16(section[i + 2] & 0x1F) << 8) | UInt16(section[i + 3])
            if programNumber != 0, pid != 0 { return pid }
            i += 4
        }
        return nil
    }

    /// PMT section → DOVI registration descriptor payload from the
    /// stream_type 0x24 (HEVC) ES entry.
    private static func parsePMT(_ payload: Data) -> DiscDoviConfig? {
        var config: DiscDoviConfig?
        withPMTEntries(payload) { streamType, descriptors in
            guard streamType == 0x24, config == nil else { return }  // HEVC
            config = doviConfigInDescriptors(descriptors)
        }
        return config
    }

    /// Walks the PMT's ES entry list, invoking `body` with each entry's
    /// stream_type and descriptor bytes. Returns false when `payload`
    /// isn't a parseable program_map_section.
    private static func withPMTEntries(_ payload: Data,
                                       _ body: (UInt8, Data) -> Void) -> Bool {
        guard let section = sectionBytes(from: payload) else { return false }
        let s = section.startIndex
        // table_id 0x02 = program_map_section; guards the fixed-PID 0x0100
        // candidate on generic TS where that PID may carry something else.
        guard section.count >= 12, section[s] == 0x02 else { return false }
        let sectionLength = Int(section[s + 1] & 0x0F) << 8 | Int(section[s + 2])
        let end = min(s + 3 + sectionLength - 4, section.endIndex)
        let programInfoLength = Int(section[s + 10] & 0x0F) << 8 | Int(section[s + 11])
        var i = s + 12 + programInfoLength
        while i + 5 <= end {
            let streamType = section[i]
            let esInfoLength = Int(section[i + 3] & 0x0F) << 8 | Int(section[i + 4])
            let esInfoEnd = min(i + 5 + esInfoLength, end)
            body(streamType, section.subdata(in: i + 5..<esInfoEnd))
            i = esInfoEnd
        }
        return true
    }

    private static func pmtDescription(_ payload: Data) -> String {
        var lines: [String] = []
        withPMTEntries(payload) { streamType, descriptors in
            var tags: [String] = []
            var i = descriptors.startIndex
            while i + 2 <= descriptors.endIndex {
                let tag = descriptors[i]
                let len = Int(descriptors[i + 1])
                guard i + 2 + len <= descriptors.endIndex else { break }
                if tag == 0x05, len >= 4 {
                    let ident = (UInt32(descriptors[i + 2]) << 24) | (UInt32(descriptors[i + 3]) << 16)
                        | (UInt32(descriptors[i + 4]) << 8) | UInt32(descriptors[i + 5])
                    tags.append("reg(\(String(format: "0x%08X", ident)))")
                } else {
                    tags.append(String(format: "0x%02X", tag))
                }
                i += 2 + len
            }
            lines.append("es type=\(String(format: "0x%02X", streamType)) desc=[\(tags.joined(separator: ","))]")
        }
        return lines.isEmpty ? "pmt=unparseable" : lines.joined(separator: "; ")
    }

    /// Walks the descriptor loop looking for registration_descriptor
    /// (tag 0x05) with format_identifier 'DOVI' followed by the 24-byte
    /// config record.
    private static func doviConfigInDescriptors(_ data: Data) -> DiscDoviConfig? {
        var i = data.startIndex
        while i + 2 <= data.endIndex {
            let tag = data[i]
            let len = Int(data[i + 1])
            guard i + 2 + len <= data.endIndex else { break }
            if tag == 0x05, len >= 5,
               data[i + 2] == 0x44, data[i + 3] == 0x4F,
               data[i + 4] == 0x56, data[i + 5] == 0x49 {  // 'DOVI'
                if len - 4 >= 5 {
                    return parseDoviRecord(data, from: data.index(i, offsetBy: 6))
                }
            }
            i += 2 + len
        }
        return nil
    }

    // MARK: - dvcC record

    /// 24-byte dvcC bit layout (identical to the mp4 dvcC box payload):
    /// major(8) minor(8) profile(7) level(6) rpu(1) el(1) bl(1) compatId(4)
    /// md_compression(1) ...
    private static func parseDoviRecord(_ data: Data, from recordStart: Data.Index) -> DiscDoviConfig {
        let s = recordStart
        let b2 = data[s + 2]
        let b3 = data[s + 3]
        let b4 = data[s + 4]
        return DiscDoviConfig(
            versionMajor: data[s],
            versionMinor: data[s + 1],
            profile: (b2 >> 1) & 0x7F,
            level: ((b2 & 0x01) << 5) | ((b3 >> 3) & 0x1F),
            rpuPresent: (b3 >> 2) & 0x01 == 1,
            elPresent: (b3 >> 1) & 0x01 == 1,
            blPresent: b3 & 0x01 == 1,
            blSignalCompatibilityId: (b4 >> 4) & 0x0F
        )
    }

    /// Strips the pointer_field and returns the section bytes.
    private static func sectionBytes(from payload: Data) -> Data? {
        guard payload.count >= 2 else { return nil }
        let pointer = Int(payload[payload.startIndex])
        guard payload.startIndex + 1 + pointer < payload.endIndex else { return nil }
        return payload.subdata(in: payload.startIndex + 1 + pointer..<payload.endIndex)
    }
}
