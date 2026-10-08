import XCTest
import CFFmpeg
@testable import PlayerKitNative

/// Unit tests for the ST 2094-40 (HDR10+) side-data parser in
/// `FFmpegVideoDecoder.parseHDR10Plus` — hand-built `AVDynamicHDRPlus`
/// structs, no demux/decode involved.
final class HDR10PlusParseTests: XCTestCase {

    // MARK: - Fixtures

    /// Zero-initialised `AVDynamicHDRPlus` with window 0 configured for a
    /// tone-mapping curve over `anchors`. Rationals use the SEI's nominal
    /// grids (knee/anchors 1/1023, targeted luminance 0.0001 cd/m²) but the
    /// parser only ever divides num by den.
    private func makeHDRPlus(
        toneMappingFlag: UInt8,
        kneeX: AVRational = AVRational(num: 0, den: 1),
        kneeY: AVRational = AVRational(num: 0, den: 1),
        anchors: [AVRational],
        targetedLum: AVRational = AVRational(num: 0, den: 1)
    ) -> AVDynamicHDRPlus {
        var h = AVDynamicHDRPlus()
        h.num_windows = 1
        h.params.0.tone_mapping_flag = toneMappingFlag
        h.params.0.knee_point_x = kneeX
        h.params.0.knee_point_y = kneeY
        h.params.0.num_bezier_curve_anchors = UInt8(anchors.count)
        for (i, a) in anchors.enumerated() {
            setAnchor(&h, i, a)
        }
        h.targeted_system_display_maximum_luminance = targetedLum
        return h
    }

    /// C fixed-size array members import as tuples with no dynamic subscript;
    /// rebind to the element type to index them.
    private func setAnchor(_ h: inout AVDynamicHDRPlus, _ index: Int, _ value: AVRational) {
        withUnsafeMutablePointer(to: &h.params.0.bezier_curve_anchors) { tuple in
            tuple.withMemoryRebound(to: AVRational.self, capacity: 15) { pts in
                pts[index] = value
            }
        }
    }

    // MARK: - Curve extraction

    func testParsesKneeAndAnchorsIntoControlPointVector() {
        // knee (0.4, 0.5), anchors 0.2/0.3/0.6 → P = [0, .2, .3, .6, 1]
        let h = makeHDRPlus(
            toneMappingFlag: 1,
            kneeX: AVRational(num: 4092, den: 10230),
            kneeY: AVRational(num: 5115, den: 10230),
            anchors: [
                AVRational(num: 2046, den: 10230),
                AVRational(num: 3069, den: 10230),
                AVRational(num: 6138, den: 10230),
            ])
        let curve = FFmpegVideoDecoder.parseHDR10Plus(h)?.bezierCurve
        XCTAssertNotNil(curve)
        XCTAssertEqual(curve?.count, 5)
        XCTAssertEqual(curve?.kneePointX ?? -1, 0.4, accuracy: 1e-4)
        XCTAssertEqual(curve?.kneePointY ?? -1, 0.5, accuracy: 1e-4)
        // Control-point vector: fixed 0, SEI anchors in order, fixed 1.
        XCTAssertEqual(curve?.anchors.0 ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(curve?.anchors.1 ?? -1, 0.2, accuracy: 1e-4)
        XCTAssertEqual(curve?.anchors.2 ?? -1, 0.3, accuracy: 1e-4)
        XCTAssertEqual(curve?.anchors.3 ?? -1, 0.6, accuracy: 1e-4)
        XCTAssertEqual(curve?.anchors.4 ?? -1, 1, accuracy: 1e-6)
    }

    func testTruncatesMoreThanEightAnchors() {
        // 15 anchors is the ST 2094-40 maximum; the 10-slot P vector holds at
        // most 8 of them between the two fixed endpoints.
        let anchors = (0..<15).map { AVRational(num: Int32($0 + 1) * 682, den: 10230) }
        var h = makeHDRPlus(
            toneMappingFlag: 1,
            kneeX: AVRational(num: 1023, den: 10230),
            kneeY: AVRational(num: 1023, den: 10230),
            anchors: anchors)
        let curve = FFmpegVideoDecoder.parseHDR10Plus(h)?.bezierCurve
        XCTAssertEqual(curve?.count, 10)
        // P[8] holds the 8th SEI anchor (index 7); the 9th (index 8) and
        // beyond are truncated; P[9] is the fixed endpoint.
        XCTAssertEqual(curve?.anchors.8 ?? -1, Float(8 * 682) / 10230, accuracy: 1e-4)
        XCTAssertEqual(curve?.anchors.9 ?? -1, 1, accuracy: 1e-6)
    }

    // MARK: - Curve gating

    func testDropsCurveWhenToneMappingFlagIsZero() {
        // SEI present but carries no curve this frame — keep static fields.
        var h = makeHDRPlus(toneMappingFlag: 0, anchors: [],
                            targetedLum: AVRational(num: 10_000_000, den: 10_000))
        let md = FFmpegVideoDecoder.parseHDR10Plus(h)
        XCTAssertNotNil(md)
        XCTAssertNil(md?.bezierCurve)
        XCTAssertEqual(md?.targetedSystemDisplayMaxLuminance, 1000)
    }

    func testDropsCurveWhenKneeOutOfRange() {
        // kx = 1 leaves the bezier segment dividing by zero; kx = 0 is the
        // "unset" marker. Either way the curve is unusable — drop it.
        var h = makeHDRPlus(
            toneMappingFlag: 1,
            kneeX: AVRational(num: 10230, den: 10230),
            kneeY: AVRational(num: 5115, den: 10230),
            anchors: [AVRational(num: 2046, den: 10230)])
        XCTAssertNil(FFmpegVideoDecoder.parseHDR10Plus(h)?.bezierCurve)
    }

    // MARK: - Structure sanity

    func testReturnsNilWithoutWindows() {
        var h = makeHDRPlus(toneMappingFlag: 1, anchors: [AVRational(num: 1, den: 2)])
        h.num_windows = 0
        XCTAssertNil(FFmpegVideoDecoder.parseHDR10Plus(h))
    }
}
