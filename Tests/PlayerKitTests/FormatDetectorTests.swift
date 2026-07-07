import XCTest
@testable import PlayerKit

final class FormatDetectorTests: XCTestCase {
    func testH264IsHardwareDecodable() {
        XCTAssertTrue(FormatDetector.isHardwareDecodable(codecId: "h264"))
    }

    func testHEVCIsHardwareDecodable() {
        XCTAssertTrue(FormatDetector.isHardwareDecodable(codecId: "hevc"))
    }

    func testAV1IsHardwareDecodable() {
        XCTAssertNoThrow(FormatDetector.isHardwareDecodable(codecId: "av1"))
    }

    func testVP9IsNotHardwareDecodable() {
        XCTAssertFalse(FormatDetector.isHardwareDecodable(codecId: "vp9"))
    }

    func testVC1IsNotHardwareDecodable() {
        XCTAssertFalse(FormatDetector.isHardwareDecodable(codecId: "vc1"))
    }

    func testUnknownCodecIsNotHardwareDecodable() {
        XCTAssertFalse(FormatDetector.isHardwareDecodable(codecId: "flv1"))
    }
}
