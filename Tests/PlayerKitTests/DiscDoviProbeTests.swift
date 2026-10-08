import XCTest
@testable import PlayerKit

/// Tests for extracting the Dolby Vision configuration record from a
/// Blu-ray M2TS / generic MPEG-TS byte stream. UHD Blu-ray discs carry the
/// DV config in the video ES's PMT registration descriptor ('DOVI') —
/// the same 24-byte payload as the mp4 dvcC box — which ffmpeg's mpegts
/// demuxer never surfaces as codecpar side data.
final class DiscDoviProbeTests: XCTestCase {

    // MARK: - TS packet builders

    /// 188-byte TS packet with sync byte and adaptation-field stuffing to
    /// reach the payload offset.
    private func tsPacket(pid: UInt16, payload: Data, pusi: Bool = false) -> Data {
        var p = Data([0x47])
        let pidHi = UInt8((pid >> 8) & 0x1F) | (pusi ? 0x40 : 0)
        p.append(pidHi)
        p.append(UInt8(pid & 0xFF))
        // 0x10: payload-only, no adaptation field, no scrambling,
        // continuity counter 0 (CC lives in this byte's low 4 bits).
        p.append(0x10)
        p.append(payload)
        while p.count < 188 { p.append(0xFF) }
        return Data(p.prefix(188))
    }

    /// PAT section: one program (number `programNumber`) → PMT at `pmtPid`.
    private func patPacket(programNumber: UInt16, pmtPid: UInt16) -> Data {
        var section = Data([0x00])  // table_id
        // section_length counts bytes AFTER this field through CRC:
        // tsid(2) + version(1) + section/last(2) + program(4) + CRC(4) = 13
        let sectionLength = UInt16(13)
        section.append(UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)))
        section.append(UInt8(sectionLength & 0xFF))
        section.append(contentsOf: [0x00, 0x01])            // transport_stream_id
        section.append(0xC1)                                 // version, current_next
        section.append(0x00); section.append(0x00)          // section_number/last
        section.append(UInt8(programNumber >> 8))
        section.append(UInt8(programNumber & 0xFF))
        section.append(UInt8(0xE0 | ((pmtPid >> 8) & 0x1F)))
        section.append(UInt8(pmtPid & 0xFF))
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC32 (not verified)
        return tsPacket(pid: 0x0000, payload: Data([0x00]) + section, pusi: true)
    }

    /// PMT section: video ES at `videoPid` (stream_type 0x24 HEVC) carrying a
    /// 'DOVI' registration descriptor whose payload is `doviConfig`.
    private func pmtSection(videoPid: UInt16, doviConfig: Data) -> Data {
        // Registration descriptor: tag 0x05, len = 4 ('DOVI') + config
        var desc = Data([0x05, UInt8(4 + doviConfig.count)])
        desc.append(contentsOf: [0x44, 0x4F, 0x56, 0x49])  // 'DOVI'
        desc.append(doviConfig)

        var es = Data([0x24])  // stream_type HEVC
        es.append(UInt8(0xE0 | ((videoPid >> 8) & 0x1F)))
        es.append(UInt8(videoPid & 0xFF))
        es.append(UInt8(0xF0 | ((desc.count >> 8) & 0x0F)))
        es.append(UInt8(desc.count & 0xFF))
        es.append(desc)

        var section = Data([0x02])
        let sectionLength = UInt16(9 + es.count + 4)
        section.append(UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)))
        section.append(UInt8(sectionLength & 0xFF))
        section.append(contentsOf: [0x00, 0x01])            // program_number
        section.append(0xC1)
        section.append(0x00); section.append(0x00)
        section.append(0xE0); section.append(0x10)          // PCR PID = video
        section.append(0xF0); section.append(0x00)          // no program info
        section.append(es)
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return section
    }

    /// PMT packet: section wrapped at PID 0x1000 (a PAT-assigned PMT PID).
    private func pmtPacket(videoPid: UInt16, doviConfig: Data) -> Data {
        tsPacket(pid: 0x1000,
                 payload: Data([0x00]) + pmtSection(videoPid: videoPid, doviConfig: doviConfig),
                 pusi: true)
    }

    /// 24-byte DV config record (dvcC bit layout), profile 7 level 6,
    /// RPU/EL/BL present, compat id 1, md_compression unlimited.
    private func dvcc(profile: UInt8 = 7, level: UInt8 = 6,
                      rpu: Bool = true, el: Bool = true, bl: Bool = true,
                      compatId: UInt8 = 1) -> Data {
        var b2 = UInt8((profile & 0x7F) << 1)
        b2 |= (level >> 5) & 0x01
        var b3 = UInt8((level & 0x1F) << 3)
        b3 |= (rpu ? 1 : 0) << 2
        b3 |= (el ? 1 : 0) << 1
        b3 |= bl ? 1 : 0
        var b4 = UInt8((compatId & 0x0F) << 4)
        b4 |= 0 << 3  // dv_md_compression = unlimited
        var d = Data([0x01, 0x00, b2, b3, b4])  // v1.0
        while d.count < 24 { d.append(0x00) }
        return d
    }

    /// Minimal M2TS stream: PAT + PMT, wrapped in 192-byte packets
    /// (4-byte TP_extra_header prefix, as on UHD Blu-ray).
    private func m2tsStream(doviConfig: Data?) -> Data {
        var out = Data()
        let pat = patPacket(programNumber: 1, pmtPid: 0x1000)
        let pmt = pmtPacket(videoPid: 0x1011, doviConfig: doviConfig ?? Data())
        for tp in [pat, pmt] {
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // TP_extra_header
            out.append(tp)
        }
        return out
    }

    // MARK: - Extraction

    func testExtractsDoviConfigFromUHDBDM2TS() {
        let stream = m2tsStream(doviConfig: dvcc())
        let config = DiscDoviProbe.extractDoviConfig(from: stream)
        XCTAssertNotNil(config, "PMT 带 DOVI registration descriptor 的原盘应提取出 config")
        XCTAssertEqual(config?.versionMajor, 1)
        XCTAssertEqual(config?.versionMinor, 0)
        XCTAssertEqual(config?.profile, 7)
        XCTAssertEqual(config?.level, 6)
        XCTAssertEqual(config?.rpuPresent, true)
        XCTAssertEqual(config?.elPresent, true)
        XCTAssertEqual(config?.blPresent, true)
        XCTAssertEqual(config?.blSignalCompatibilityId, 1)
    }

    func testExtractsFromPlain188ByteTS() {
        // Same sections without the 4-byte TP_extra_header (raw TS).
        var stream = patPacket(programNumber: 1, pmtPid: 0x1000)
        stream.append(pmtPacket(videoPid: 0x1011, doviConfig: dvcc()))
        let config = DiscDoviProbe.extractDoviConfig(from: stream)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.profile, 7)
    }

    func testExtractsFromBdmvM2tsWithoutPat() {
        // BDMV M2TS carries no PAT — the PMT lives at the fixed PID 0x0100
        // (playlist/clpi drives stream selection instead of SI tables).
        let pmt = tsPacket(pid: 0x0100,
                           payload: Data([0x00]) + pmtSection(videoPid: 0x1011, doviConfig: dvcc()),
                           pusi: true)
        let config = DiscDoviProbe.extractDoviConfig(from: pmt)
        XCTAssertNotNil(config, "PMT at fixed BDMV PID should be found without a PAT")
        XCTAssertEqual(config?.profile, 7)
    }

    /// M2TS with the HEVC video on PES packets whose payload carries an
    /// annexb unspec62 EL NAL: 2-byte NAL header + el_type(0x02) + the
    /// 24-byte DV config record — how UHD Blu-ray P7 carries the config
    /// (its PMT registration descriptor is 'HDMV', not 'DOVI').
    func testExtractsDoviConfigFromUnspec62ELNal() {
        var el = Data([0x7C, 0x01])         // NAL header: type 62, tid 1
        el.append(0x02)                     // el_type = 2 (EL, config nested)
        el.append(dvcc())                   // 24-byte config record
        el.append(contentsOf: [0xAA, 0xBB, 0xCC])  // EL slice data
        // annexb stream: IDR NAL, then the unspec62 EL NAL
        var stream = Data()
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAF])  // IDR
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        stream.append(el)
        let data = m2tsStream(doviConfig: nil) + pesPacket(pid: 0x1011, streamId: 0xE0, payload: stream)
        let config = DiscDoviProbe.extractDoviConfig(from: data)
        XCTAssertNotNil(config, "EL NAL 里的 24 字节 config 应被提取")
        XCTAssertEqual(config?.profile, 7)
        XCTAssertEqual(config?.rpuPresent, true)
    }

    /// Wraps `payload` as a PES packet on `pid` inside 192-byte M2TS
    /// packets (multiple TS packets if it doesn't fit one).
    private func pesPacket(pid: UInt16, streamId: UInt8, payload: Data) -> Data {
        var pes = Data([0x00, 0x00, 0x01, streamId])
        let len = UInt16(payload.count + 8)
        pes.append(UInt8(len >> 8)); pes.append(UInt8(len & 0xFF))
        pes.append(0x84)                    // flags: PTS present
        pes.append(0x80)
        pes.append(0x05)                    // header_data_length
        pes.append(contentsOf: [0x21, 0x00, 0x0A, 0x7A, 0x7C])  // PTS
        pes.append(payload)

        var out = Data()
        var i = pes.startIndex
        var cc: UInt8 = 0
        var first = true
        while i < pes.endIndex {
            let chunk = pes.subdata(in: i..<min(i + 184, pes.endIndex))
            var p = Data([0x47])
            p.append(UInt8((pid >> 8) & 0x1F) | (first ? 0x40 : 0))
            p.append(UInt8(pid & 0xFF))
            p.append(0x10 | cc)
            p.append(chunk)
            while p.count < 188 { p.append(0xFF) }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            out.append(Data(p.prefix(188)))
            i += 184
            cc = (cc + 1) & 0x0F
            first = false
        }
        return out
    }

    func testNilWhenNoDoviDescriptor() {
        let stream = m2tsStream(doviConfig: nil)
        XCTAssertNil(DiscDoviProbe.extractDoviConfig(from: stream))
    }

    func testNilOnTruncatedStream() {
        let stream = m2tsStream(doviConfig: dvcc())
        XCTAssertNil(DiscDoviProbe.extractDoviConfig(from: stream.prefix(60)))
        XCTAssertNil(DiscDoviProbe.extractDoviConfig(from: Data([0x47, 0x40, 0x00, 0x10])))
    }

    func testNilOnGarbage() {
        var garbage = Data()
        for i in 0..<4096 { garbage.append(UInt8(truncatingIfNeeded: i * 7919)) }
        XCTAssertNil(DiscDoviProbe.extractDoviConfig(from: garbage))
    }

    func testProfile8Config() {
        // IPT (P8.1) TS: profile 8, level 4, RPU only, compat id 2.
        let stream = m2tsStream(doviConfig: dvcc(profile: 8, level: 4,
                                                 rpu: true, el: false, bl: true,
                                                 compatId: 2))
        let config = DiscDoviProbe.extractDoviConfig(from: stream)
        XCTAssertEqual(config?.profile, 8)
        XCTAssertEqual(config?.level, 4)
        XCTAssertEqual(config?.rpuPresent, true)
        XCTAssertEqual(config?.elPresent, false)
        XCTAssertEqual(config?.blSignalCompatibilityId, 2)
    }
}
