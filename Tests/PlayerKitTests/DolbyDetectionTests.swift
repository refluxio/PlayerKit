import XCTest
@testable import PlayerKit

final class DolbyDetectionTests: XCTestCase {

    func testVideoInfoDefaultNotDolbyVision() {
        let info = VideoInfo(width: 1920, height: 1080)
        XCTAssertFalse(info.isDolbyVision)
    }

    func testVideoInfoDolbyVisionFlag() {
        let info = VideoInfo(width: 3840, height: 2160, isDolbyVision: true)
        XCTAssertTrue(info.isDolbyVision)
    }

    func testTrackInfoDefaultNotAtmos() {
        let track = TrackInfo(id: 0, codec: "eac3")
        XCTAssertFalse(track.isAtmos)
    }

    func testTrackInfoAtmosFlag() {
        let track = TrackInfo(id: 0, title: "Dolby Atmos 7.1", codec: "eac3", isAtmos: true)
        XCTAssertTrue(track.isAtmos)
        XCTAssertEqual(track.codec, "eac3")
    }

    func testTrackInfoTrueHDAtmos() {
        let track = TrackInfo(id: 1, codec: "truehd", isAtmos: true)
        XCTAssertTrue(track.isAtmos)
        XCTAssertEqual(track.codec, "truehd")
    }
}
