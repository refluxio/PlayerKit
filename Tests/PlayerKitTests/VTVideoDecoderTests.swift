import XCTest
@testable import PlayerKitNative

final class VTVideoDecoderTests: XCTestCase {

    // MARK: - HVCC parser

    func testParseHVCC_validSynthetic() {
        // Minimal HVCC: configurationVersion=1, 21 bytes padding, numArrays=3
        // VPS  (type=32=0x20): 1 NALU, length 2, data [0x40, 0x01]
        // SPS  (type=33=0x21): 1 NALU, length 2, data [0x42, 0x01]
        // PPS  (type=34=0x22): 1 NALU, length 2, data [0x44, 0x01]
        var hvcc: [UInt8] = [0x01]
        hvcc += Array(repeating: 0x00, count: 21)  // padding
        hvcc += [0x03]                               // numOfArrays = 3
        // VPS array
        hvcc += [0x20, 0x00, 0x01, 0x00, 0x02, 0x40, 0x01]
        // SPS array
        hvcc += [0x21, 0x00, 0x01, 0x00, 0x02, 0x42, 0x01]
        // PPS array
        hvcc += [0x22, 0x00, 0x01, 0x00, 0x02, 0x44, 0x01]

        let ps = VTVideoDecoder.parseHVCC(hvcc)
        XCTAssertNotNil(ps)
        XCTAssertEqual(ps?.vps.first, [0x40, 0x01])
        XCTAssertEqual(ps?.sps.first, [0x42, 0x01])
        XCTAssertEqual(ps?.pps.first, [0x44, 0x01])
    }

    func testParseHVCC_wrongVersion() {
        var hvcc: [UInt8] = [0x02]  // bad configurationVersion
        hvcc += Array(repeating: 0x00, count: 21) + [0x00]
        XCTAssertNil(VTVideoDecoder.parseHVCC(hvcc))
    }

    func testParseHVCC_tooShort() {
        let hvcc: [UInt8] = [0x01, 0x00, 0x00]
        XCTAssertNil(VTVideoDecoder.parseHVCC(hvcc))
    }

    func testParseHVCC_missingSPS() {
        // Only VPS + PPS, no SPS → should return nil
        var hvcc: [UInt8] = [0x01]
        hvcc += Array(repeating: 0x00, count: 21)
        hvcc += [0x02]  // numOfArrays = 2
        hvcc += [0x20, 0x00, 0x01, 0x00, 0x02, 0x40, 0x01]  // VPS
        hvcc += [0x22, 0x00, 0x01, 0x00, 0x02, 0x44, 0x01]  // PPS
        XCTAssertNil(VTVideoDecoder.parseHVCC(hvcc))
    }

    // MARK: - Annex B splitter

    func testSplitAnnexB_fourByteStartCodes() {
        // Two NALs separated by 4-byte start codes
        let input: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x40, 0xAA,       // VPS NAL: [0x40, 0xAA]
            0x00, 0x00, 0x00, 0x01, 0x42, 0xBB, 0xCC   // SPS NAL: [0x42, 0xBB, 0xCC]
        ]
        let nalUnits = VTVideoDecoder.splitAnnexB(input)
        XCTAssertEqual(nalUnits.count, 2)
        XCTAssertEqual(nalUnits[0], [0x40, 0xAA])
        XCTAssertEqual(nalUnits[1], [0x42, 0xBB, 0xCC])
    }

    func testSplitAnnexB_threeByteStartCodes() {
        let input: [UInt8] = [
            0x00, 0x00, 0x01, 0x40, 0xAA,
            0x00, 0x00, 0x01, 0x42, 0xBB
        ]
        let nalUnits = VTVideoDecoder.splitAnnexB(input)
        XCTAssertEqual(nalUnits.count, 2)
        XCTAssertEqual(nalUnits[0], [0x40, 0xAA])
        XCTAssertEqual(nalUnits[1], [0x42, 0xBB])
    }

    func testSplitAnnexB_single() {
        let input: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x02]
        let nalUnits = VTVideoDecoder.splitAnnexB(input)
        XCTAssertEqual(nalUnits.count, 1)
        XCTAssertEqual(nalUnits[0], [0x26, 0x01, 0x02])
    }

    // MARK: - Annex B → length-prefixed

    func testAnnexBToLengthPrefixed_twoNALs() {
        let input: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x26, 0x01,   // IDR NAL [0x26, 0x01]
            0x00, 0x00, 0x00, 0x01, 0x28, 0x02     // Another NAL [0x28, 0x02]
        ]
        let out = VTVideoDecoder.annexBToLengthPrefixed(input)
        // Expected: [0x00, 0x00, 0x00, 0x02, 0x26, 0x01, 0x00, 0x00, 0x00, 0x02, 0x28, 0x02]
        let expected: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0x26, 0x01,
                                 0x00, 0x00, 0x00, 0x02, 0x28, 0x02]
        XCTAssertEqual(Array(out), expected)
    }

    // MARK: - annexBToLengthPrefixedClassified (single-pass packet path)

    private func classified(_ bytes: [UInt8], isH264: Bool) -> (out: [UInt8], isIDR: Bool) {
        var data = Data()
        var idr = false
        bytes.withUnsafeBufferPointer { raw in
            idr = VTVideoDecoder.annexBToLengthPrefixedClassified(raw, isH264: isH264, into: &data)
        }
        return (Array(data), idr)
    }

    /// Byte-for-byte parity with the legacy two-scan pipeline:
    /// splitAnnexB → filter out parameter sets → length-prefixed join.
    func testClassified_matchesLegacyFilteredOutput_h264() {
        let input: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00,       // SPS (type 7)
            0x00, 0x00, 0x00, 0x01, 0x68, 0xEB,             // PPS (type 8)
            0x00, 0x00, 0x00, 0x01, 0x65, 0xAA, 0xBB,       // IDR slice (type 5)
            0x00, 0x00, 0x01, 0x41, 0x9A, 0x2B              // non-IDR slice (type 1), 3-byte start code
        ]
        let got = classified(input, isH264: true)

        let nalUnits = VTVideoDecoder.splitAnnexB(input).filter { nalu -> Bool in
            guard !nalu.isEmpty else { return false }
            let t = Int(nalu[0] & 0x1F)
            return t != 7 && t != 8
        }
        var expected = Data()
        for nalu in nalUnits {
            var len = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &len) { expected.append(contentsOf: $0) }
            expected.append(contentsOf: nalu)
        }
        XCTAssertEqual(got.out, Array(expected))
        XCTAssertTrue(got.isIDR)
    }

    func testClassified_detectsH264IDR() {
        let idr: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65, 0x01]
        XCTAssertTrue(classified(idr, isH264: true).isIDR)

        let nonIDR: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x41, 0x01]
        XCTAssertFalse(classified(nonIDR, isH264: true).isIDR)
    }

    /// HEVC NAL header first byte is (type << 1) for layer 0: 19/20 are the
    /// IDR_W_RADL/IDR_N_LP types. The legacy probe checked H.264 type 5
    /// regardless of codec, so HEVC IDR packets were never classified as IDR.
    func testClassified_detectsHEVCIDR() {
        let idrW: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x01]  // type 19
        XCTAssertTrue(classified(idrW, isH264: false).isIDR)

        let idrN: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x28, 0x01, 0x01]  // type 20
        XCTAssertTrue(classified(idrN, isH264: false).isIDR)

        let trailR: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x01]  // type 1
        XCTAssertFalse(classified(trailR, isH264: false).isIDR)
    }

    func testClassified_stripsHEVCParameterSets() {
        let input: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01,             // VPS (type 32)
            0x00, 0x00, 0x00, 0x01, 0x42, 0x01,             // SPS (type 33)
            0x00, 0x00, 0x00, 0x01, 0x44, 0x01,             // PPS (type 34)
            0x00, 0x00, 0x00, 0x01, 0x28, 0x01, 0x01        // IDR (type 20)
        ]
        let got = classified(input, isH264: false)

        // Only the IDR NAL survives, as a 4-byte length prefix + NAL bytes.
        let expected: [UInt8] = [0x00, 0x00, 0x00, 0x03, 0x28, 0x01, 0x01]
        XCTAssertEqual(got.out, expected)
        XCTAssertTrue(got.isIDR)
    }

    func testClassified_allParameterSetsYieldsEmptyAndNoIDR() {
        let input: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x67, 0x64,
            0x00, 0x00, 0x00, 0x01, 0x68, 0xEB
        ]
        let got = classified(input, isH264: true)
        XCTAssertTrue(got.out.isEmpty)
        XCTAssertFalse(got.isIDR)
    }

    func testClassified_emptyInputYieldsEmpty() {
        let got = classified([], isH264: true)
        XCTAssertTrue(got.out.isEmpty)
        XCTAssertFalse(got.isIDR)
    }
}
