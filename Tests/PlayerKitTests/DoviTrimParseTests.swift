import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// Unit tests for the DoVi DM extension-block parsers in
/// `FFmpegVideoDecoder` — hand-built C structs, no demux/decode involved.
///
/// Conversion semantics follow libdovi's XML mapping (creative lifts/gains
/// encoded around a 2048 midpoint on the 12-bit RPU grid):
///   slope  = raw / 2048        (midpoint 1.0, multiplicative)
///   offset = raw / 2048 - 1    (midpoint 0.0, additive)
///   power  = raw / 2048        (midpoint 1.0, gamma exponent)
///   chroma / saturation        (midpoint 1.0 per field name; usable as
///                             offset = value - 1)
///   L3 PQ offsets = raw / 2048 - 1, additive in normalised PQ domain.
final class DoviTrimParseTests: XCTestCase {

    // MARK: - Level 1 alignment

    /// RPU PQ codes are 12-bit; the public 16-bit field must receive them
    /// MSB-aligned so consumers can keep dividing by 65535.
    func testLevel1Aligns12BitCodesTo16Bit() {
        var l1 = AVDOVIDmLevel1()
        l1.min_pq = 0x0ABC
        l1.max_pq = 0xFFF
        l1.avg_pq = 0x001
        let level1 = FFmpegVideoDecoder.parseDoviLevel1(l1)
        XCTAssertEqual(level1.minPq, 0xABC0)
        XCTAssertEqual(level1.maxPq, 0xFFF0)
        XCTAssertEqual(level1.avgPq, 0x0010)
    }

    // MARK: - Level 2 trim

    /// The all-2048 default block (libdovi `ExtMetadataBlockLevel2.default`)
    /// must decode to the identity trim.
    func testLevel2NeutralIsIdentity() {
        var dm = AVDOVIDmData()
        dm.level = 2
        dm.l2.target_max_pq = 2081
        dm.l2.trim_slope = 2048
        dm.l2.trim_offset = 2048
        dm.l2.trim_power = 2048
        dm.l2.trim_chroma_weight = 2048
        dm.l2.trim_saturation_gain = 2048
        dm.l2.ms_weight = 2048
        let l2 = FFmpegVideoDecoder.parseDoviTrim(dm)
        XCTAssertNotNil(l2)
        XCTAssertEqual(l2?.targetMaxPq, 2081)
        XCTAssertEqual(l2?.trimSlope ?? -1, 1.0, accuracy: 1e-6)
        XCTAssertEqual(l2?.trimOffset ?? -1, 0.0, accuracy: 1e-6)
        XCTAssertEqual(l2?.trimPower ?? -1, 1.0, accuracy: 1e-6)
        XCTAssertEqual(l2?.trimSaturationGain ?? -1, 1.0, accuracy: 1e-6)
        XCTAssertEqual(l2?.msWeight, 2048)
    }

    /// Non-neutral trims decode per the libdovi midpoint table. slope 3072 →
    /// 1.5×, offset 3072 → +0.5, power 683 → ⅓ (a positive lift/gamma trim),
    /// saturation 1024 → 0.5×.
    func testLevel2DecodesNonNeutralTrims() {
        var dm = AVDOVIDmData()
        dm.level = 2
        dm.l2.target_max_pq = 2081
        dm.l2.trim_slope = 3072
        dm.l2.trim_offset = 3072
        dm.l2.trim_power = 683
        dm.l2.trim_chroma_weight = 2048
        dm.l2.trim_saturation_gain = 1024
        dm.l2.ms_weight = -1
        let l2 = FFmpegVideoDecoder.parseDoviTrim(dm)
        XCTAssertEqual(l2?.trimSlope ?? -1, 1.5, accuracy: 1e-6)
        XCTAssertEqual(l2?.trimOffset ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(l2?.trimPower ?? -1, 683.0 / 2048.0, accuracy: 1e-6)
        XCTAssertEqual(l2?.trimSaturationGain ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(l2?.msWeight, -1)
    }

    /// Level 8 carries the same six trim fields plus a target index; it must
    /// decode through the same conversion.
    func testLevel8DecodesThroughSameConversion() {
        var dm = AVDOVIDmData()
        dm.level = 8
        dm.l8.target_display_index = 3
        dm.l8.trim_slope = 2560
        dm.l8.trim_offset = 2048
        dm.l8.trim_power = 2048
        dm.l8.trim_chroma_weight = 2048
        dm.l8.trim_saturation_gain = 2304
        dm.l8.ms_weight = 2048
        let l2 = FFmpegVideoDecoder.parseDoviTrim(dm)
        XCTAssertNotNil(l2)
        XCTAssertEqual(l2?.trimSlope ?? -1, 1.25, accuracy: 1e-6)
        XCTAssertEqual(l2?.trimSaturationGain ?? -1, 1.125, accuracy: 1e-6)
    }

    func testIgnoresOtherLevels() {
        var dm = AVDOVIDmData()
        dm.level = 6
        XCTAssertNil(FFmpegVideoDecoder.parseDoviTrim(dm))
    }

    // MARK: - Level 3 L1 offsets

    /// 2048 midpoint = no shift; ±1024 raw = ±0.5 PQ offset.
    func testLevel3Offsets() {
        var dm = AVDOVIDmData()
        dm.level = 3
        dm.l3.min_pq_offset = 2048
        dm.l3.max_pq_offset = 3072
        dm.l3.avg_pq_offset = 1024
        let l3 = FFmpegVideoDecoder.parseDoviLevel3(dm)
        XCTAssertNotNil(l3)
        XCTAssertEqual(l3?.minPqOffset ?? -9, 0.0, accuracy: 1e-6)
        XCTAssertEqual(l3?.maxPqOffset ?? -9, 0.5, accuracy: 1e-6)
        XCTAssertEqual(l3?.avgPqOffset ?? -9, -0.5, accuracy: 1e-6)
    }

    func testLevel3IgnoresOtherLevels() {
        var dm = AVDOVIDmData()
        dm.level = 1
        XCTAssertNil(FFmpegVideoDecoder.parseDoviLevel3(dm))
    }

    // MARK: - Level 6(静态 HDR10 兼容元数据,nits 原样透传)

    func testLevel6PassesStaticNitsThrough() {
        var dm = AVDOVIDmData()
        dm.level = 6
        dm.l6.max_luminance = 1000
        dm.l6.min_luminance = 1
        dm.l6.max_cll = 1000
        dm.l6.max_fall = 400
        let l6 = FFmpegVideoDecoder.parseDoviLevel6(dm)
        XCTAssertEqual(l6?.maxLuminance, 1000)
        XCTAssertEqual(l6?.minLuminance, 1)
        XCTAssertEqual(l6?.maxCll, 1000)
        XCTAssertEqual(l6?.maxFall, 400)
    }

    func testLevel6IgnoresOtherLevels() {
        var dm = AVDOVIDmData()
        dm.level = 1
        dm.l1.min_pq = 0; dm.l1.max_pq = 2081; dm.l1.avg_pq = 1000
        XCTAssertNil(FFmpegVideoDecoder.parseDoviLevel6(dm))
    }

    // MARK: - L8 ms_weight 负值回绕(libdovi 语义:>4095 为负半区,按 8192 回绕)

    func testLevel8NegativeMsWeightWraps() {
        var dm = AVDOVIDmData()
        dm.level = 8
        dm.l8.trim_slope = 2048; dm.l8.trim_offset = 2048; dm.l8.trim_power = 2048
        dm.l8.trim_chroma_weight = 2048; dm.l8.trim_saturation_gain = 2048
        dm.l8.ms_weight = 8192 - 512   // 原始编码 → 语义值 -512
        let trim = FFmpegVideoDecoder.parseDoviTrim(dm)
        XCTAssertEqual(trim?.msWeight, -512)
    }

    func testLevel8PositiveMsWeightPassesThrough() {
        var dm = AVDOVIDmData()
        dm.level = 8
        dm.l8.ms_weight = 1000
        XCTAssertEqual(FFmpegVideoDecoder.parseDoviTrim(dm)?.msWeight, 1000)
    }
}
