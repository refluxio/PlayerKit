import XCTest
@testable import PlayerKitNative

final class ClipTimelineTests: XCTestCase {
    func testInitFailsOnEmptyDurations() {
        XCTAssertNil(ClipTimeline(durationsSecs: []))
    }

    func testInitFailsOnZeroOrNegativeDuration() {
        XCTAssertNil(ClipTimeline(durationsSecs: [10, 0, 5]))
        XCTAssertNil(ClipTimeline(durationsSecs: [10, -1, 5]))
    }

    func testStartOffsetsAndTotalDuration() {
        let tl = ClipTimeline(durationsSecs: [10, 20, 15])!
        XCTAssertEqual(tl.startOffsets, [0, 10, 30])
        XCTAssertEqual(tl.totalDurationSecs, 45)
    }

    func testLocateAtZero() {
        let tl = ClipTimeline(durationsSecs: [10, 20, 15])!
        let (idx, local) = tl.locate(globalSecs: 0)
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(local, 0)
    }

    func testLocateInsideMiddleClip() {
        let tl = ClipTimeline(durationsSecs: [10, 20, 15])!
        let (idx, local) = tl.locate(globalSecs: 15)
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(local, 5, accuracy: 0.0001)
    }

    func testLocateExactlyAtClipBoundaryLandsInNextClip() {
        let tl = ClipTimeline(durationsSecs: [10, 20, 15])!
        let (idx, local) = tl.locate(globalSecs: 10)
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(local, 0, accuracy: 0.0001)
    }

    func testLocateInLastClip() {
        let tl = ClipTimeline(durationsSecs: [10, 20, 15])!
        let (idx, local) = tl.locate(globalSecs: 40)
        XCTAssertEqual(idx, 2)
        XCTAssertEqual(local, 10, accuracy: 0.0001)
    }

    func testLocateClampsBeyondTotalDurationToLastClipEnd() {
        let tl = ClipTimeline(durationsSecs: [10, 20, 15])!
        let (idx, local) = tl.locate(globalSecs: 999)
        XCTAssertEqual(idx, 2)
        XCTAssertEqual(local, 15, accuracy: 0.0001)
    }

    func testLocateClampsNegativeToZero() {
        let tl = ClipTimeline(durationsSecs: [10, 20, 15])!
        let (idx, local) = tl.locate(globalSecs: -5)
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(local, 0)
    }

    func testSingleClipTimeline() {
        let tl = ClipTimeline(durationsSecs: [42])!
        XCTAssertEqual(tl.startOffsets, [0])
        XCTAssertEqual(tl.totalDurationSecs, 42)
        let (idx, local) = tl.locate(globalSecs: 20)
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(local, 20, accuracy: 0.0001)
    }
}
