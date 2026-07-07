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
}
