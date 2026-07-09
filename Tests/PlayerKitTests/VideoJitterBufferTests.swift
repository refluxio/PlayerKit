import XCTest
import CoreVideo
import PlayerKit
@testable import PlayerKitNative

final class VideoJitterBufferTests: XCTestCase {

    private func makeFrame(pts: Double) -> VideoJitterBuffer.Frame {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        return VideoJitterBuffer.Frame(pixelBuffer: pixelBuffer!, pts: pts, metadata: FrameMetadata())
    }

    func testInitialStateIsBuffering() {
        let buf = VideoJitterBuffer()
        XCTAssertEqual(buf.state, .buffering)
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(buf.duration, 0.0)
    }

    func testDurationIsZeroWithOneFrame() {
        let buf = VideoJitterBuffer()
        buf.append(makeFrame(pts: 1.0))
        XCTAssertEqual(buf.duration, 0.0, "单帧无法计算时长")
    }

    func testDurationWithMultipleFrames() {
        let buf = VideoJitterBuffer()
        buf.append(makeFrame(pts: 1.0))
        buf.append(makeFrame(pts: 3.0))
        XCTAssertEqual(buf.duration, 2.0, accuracy: 0.001)
    }

    func testTransitionsToPlayingWhenResumeDurationReached() {
        let buf = VideoJitterBuffer()
        var receivedState: VideoJitterBuffer.State?
        let exp = expectation(description: "state change to playing")
        buf.onStateChange = { state in
            receivedState = state
            exp.fulfill()
        }
        // resumeDuration = 2.0s：添加 pts=0 和 pts=2.0 的帧
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedState, .playing)
        XCTAssertEqual(buf.state, .playing)
    }

    func testTransitionsToBufferingWhenBelowMinDuration() {
        let buf = VideoJitterBuffer()
        // 先进入 playing 状态
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))
        let exp1 = expectation(description: "playing")
        buf.onStateChange = { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)
        XCTAssertEqual(buf.state, .playing)

        // 弹出帧直到 duration < minDuration(0.5)
        var bufferingExp: XCTestExpectation?
        buf.onStateChange = { state in
            if state == .buffering { bufferingExp?.fulfill() }
        }
        bufferingExp = expectation(description: "buffering")
        buf.pop()  // 弹出 pts=0.0，剩余 duration=0 → 进入 buffering
        wait(for: [bufferingExp!], timeout: 1.0)
        XCTAssertEqual(buf.state, .buffering)
    }

    func testPeekAtIndex() {
        let buf = VideoJitterBuffer()
        buf.append(makeFrame(pts: 1.0))
        buf.append(makeFrame(pts: 2.0))
        buf.append(makeFrame(pts: 3.0))
        XCTAssertEqual(buf.peek(at: 0)?.pts, 1.0)
        XCTAssertEqual(buf.peek(at: 1)?.pts, 2.0)
        XCTAssertNil(buf.peek(at: 10))
    }

    func testFlushResetsToBuffering() {
        let buf = VideoJitterBuffer()
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))
        let exp = expectation(description: "playing")
        buf.onStateChange = { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        buf.flush()
        XCTAssertEqual(buf.state, .buffering)
        XCTAssertEqual(buf.count, 0)
    }

    func testSortedInsertionKeepsPTSOrder() {
        let buf = VideoJitterBuffer()
        // B-frame decode order: 0.000, 0.080, 0.040 (simulates VT decoder output)
        buf.append(makeFrame(pts: 0.000))
        buf.append(makeFrame(pts: 0.080))
        buf.append(makeFrame(pts: 0.040))
        // After sorted insertion, peek order must be 0.000, 0.040, 0.080
        XCTAssertEqual(buf.peek(at: 0)?.pts ?? -1, 0.000, accuracy: 0.001)
        XCTAssertEqual(buf.peek(at: 1)?.pts ?? -1, 0.040, accuracy: 0.001)
        XCTAssertEqual(buf.peek(at: 2)?.pts ?? -1, 0.080, accuracy: 0.001)
    }

    func testMaxFrameCountCapDropsOldest() {
        let buf = VideoJitterBuffer()
        // maxFrameCount=400: adding 401 frames should cap at 400
        for i in 0...400 {
            buf.append(makeFrame(pts: Double(i) * 0.04))
        }
        XCTAssertLessThanOrEqual(buf.count, buf.maxFrameCount)
    }
}
