import XCTest
@testable import PlayerKitNative

/// Regression tests for the 2026-09-30 "progress thumb flashes back to the old
/// position after a drag" bug.
///
/// `_seek` bumps `seekSerial` at once, but the physical demuxer seek lands 100-200 ms
/// later (a network round trip). In that gap the demux loop still reads packets from
/// the OLD position, and because it captures the already-bumped serial at the start of
/// each iteration, its frames passed the "not from before the seek" check and went
/// into the freshly flushed jitter buffer. Once 4K120 content shrank the start
/// threshold to ~17 frames, those stale frames reached `.playing`, were displayed, and
/// `displayNextFrame` wrote their old PTS into `state.position` (measured on the
/// phone: target 2027 -> 983.42 -> 2023.73 after landing).
///
/// A frame may only be kept when the LATEST seek has physically landed.
final class SeekFrameGateTests: XCTestCase {

    func testFrameBeforeAnyEverSeekIsAccepted() {
        // serial 0, nothing pending
        let landedAtStart = SeekFrameGate.landedAtIterationStart(landedSerial: 0, iterationSerial: 0)
        XCTAssertTrue(SeekFrameGate.accepts(landedAtIterationStart: landedAtStart, iterationSerial: 0, latestSerial: 0))
    }

    func testStaleFrameInTheWindowBetweenSeekAndLandingIsRejected() {
        // _seek bumped the serial to 5; the physical seek has not landed (landed is still 4).
        // The loop starts an iteration now: it captures serial 5 but the gate is closed.
        let landedAtStart = SeekFrameGate.landedAtIterationStart(landedSerial: 4, iterationSerial: 5)
        XCTAssertFalse(landedAtStart)
        XCTAssertFalse(SeekFrameGate.accepts(landedAtIterationStart: landedAtStart, iterationSerial: 5, latestSerial: 5),
                       "a frame read from the old position before the seek lands must not enter the buffer")
    }

    func testFrameAfterLandingIsAccepted() {
        let landedAtStart = SeekFrameGate.landedAtIterationStart(landedSerial: 5, iterationSerial: 5)
        XCTAssertTrue(SeekFrameGate.accepts(landedAtIterationStart: landedAtStart, iterationSerial: 5, latestSerial: 5))
    }

    func testFrameFromAnIterationThatStartedBeforeLandingButFinishedAfterIsRejected() {
        // The iteration started while the seek was still pending (gate closed), the seek
        // landed (and flushed the buffer) while the packet was being decoded, and only
        // then does the frame come back. Checking at the END would let this stale frame
        // in right after the flush.
        let landedAtStart = SeekFrameGate.landedAtIterationStart(landedSerial: 4, iterationSerial: 5)
        XCTAssertFalse(SeekFrameGate.accepts(landedAtIterationStart: landedAtStart, iterationSerial: 5, latestSerial: 5))
    }

    func testFrameFromBeforeANewerSeekIsRejectedEvenIfItsOwnSeekLanded() {
        // Existing behaviour kept: a newer seek arrived while this iteration was decoding.
        let landedAtStart = SeekFrameGate.landedAtIterationStart(landedSerial: 5, iterationSerial: 5)
        XCTAssertFalse(SeekFrameGate.accepts(landedAtIterationStart: landedAtStart, iterationSerial: 5, latestSerial: 6))
    }

    func testSupersededSeekLeavesTheGateClosedUntilTheNewestLands() {
        // Seek 5 was superseded by seek 6 before it physically ran, so only 6 ever lands.
        XCTAssertFalse(SeekFrameGate.landedAtIterationStart(landedSerial: 4, iterationSerial: 6))
        XCTAssertTrue(SeekFrameGate.landedAtIterationStart(landedSerial: 6, iterationSerial: 6))
    }
}
