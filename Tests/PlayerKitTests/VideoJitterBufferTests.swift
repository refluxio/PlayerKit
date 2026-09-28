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
        // 先进入 playing 状态。转态在 append 内同步发生,onStateChange 必须在
        // append 之前就位——事后设置不会再收到已发生过的转态。
        let exp1 = expectation(description: "playing")
        buf.onStateChange = { _ in exp1.fulfill() }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))
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
        let exp = expectation(description: "playing")
        buf.onStateChange = { _ in exp.fulfill() }
        buf.append(makeFrame(pts: 0.0))
        buf.append(makeFrame(pts: 2.0))
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
        for i in 0...(buf.maxFrameCount) {
            buf.append(makeFrame(pts: Double(i) * 0.04))
        }
        XCTAssertLessThanOrEqual(buf.count, buf.maxFrameCount)
    }

    // MARK: - 高帧率回归(120fps 冻结 bug)
    //
    // 根因:旧的 maxFrameCount 是固定 60(注释"≈2.5s at 24fps"),对 120fps 内容只等于
    // 0.5s 时长——同时低于开播门槛 resumeDuration(1.0s)和防抖门槛 minDuration(0.5s)。
    // 缓冲区永远攒不到能开播的量,只能靠 4 秒慢速兜底硬开;一旦弹出一帧,剩余时长立刻又
    // 跌破 minDuration,马上打回缓冲——形成"开播→弹一帧→冻结 4 秒"的循环,肉眼看是卡死。
    // 实测片源(4K HDR 120fps HEVC)60 秒内仅推进一次,与此机制吻合。

    func testUnconfiguredFrameRateCannotReachResumeDurationAt120fps() {
        // 未调用 configureFrameRate 时按旧行为(隐含假设低帧率内容)：以 120fps 的节奏喂帧,
        // 固定 60 帧的上限只能攒到 0.5s,永远达不到 1.0s 的开播门槛——这就是冻结的直接成因。
        let buf = VideoJitterBuffer()
        for i in 0..<200 {
            buf.append(makeFrame(pts: Double(i) / 120.0))
        }
        XCTAssertLessThan(buf.duration, buf.resumeDuration,
                          "不配置帧率时,120fps 内容的缓冲区应该(错误地)攒不到开播门槛——复现冻结")
    }

    func testConfiguredFrameRateReachesResumeDurationAt120fps() {
        // 修复:告知实际帧率后,上限按帧率换算,120fps 内容能正常攒够并开播。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(120)
        var receivedState: VideoJitterBuffer.State?
        let exp = expectation(description: "state change to playing")
        buf.onStateChange = { state in
            receivedState = state
            exp.fulfill()
        }
        for i in 0..<200 {
            buf.append(makeFrame(pts: Double(i) / 120.0))
            if buf.state == .playing { break }
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedState, .playing)
        XCTAssertGreaterThanOrEqual(buf.duration, buf.resumeDuration)
    }

    func testConfiguredFrameRateSurvivesOnePopWithoutImmediatelyRebuffering() {
        // 修复的第二层:光能开播不够——原 bug 是"开播后弹一帧立刻又跌破 minDuration"的
        // 反复横跳。验证弹出一帧后剩余时长仍 >= minDuration,不会立刻打回缓冲。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(120)
        for i in 0..<200 {
            buf.append(makeFrame(pts: Double(i) / 120.0))
            if buf.state == .playing { break }
        }
        XCTAssertEqual(buf.state, .playing)
        buf.pop()
        XCTAssertEqual(buf.state, .playing,
                       "120fps 下弹出一帧不应该让剩余时长跌破 minDuration、立刻打回缓冲")
    }

    func testLowFrameRateCapIsUnchanged() {
        // 向后兼容:24fps(及默认未配置)时上限仍是 60,不因为这次修复放大内存占用。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(24)
        XCTAssertEqual(buf.maxFrameCount, 60)
    }

    func testZeroOrNegativeFrameRateIsIgnored() {
        // 防御:非法帧率(0、负数、非有限值)不应该把上限改小或崩溃,保留原有安全值。
        let buf = VideoJitterBuffer()
        buf.configureFrameRate(0)
        XCTAssertEqual(buf.maxFrameCount, 60)
        buf.configureFrameRate(-30)
        XCTAssertEqual(buf.maxFrameCount, 60)
        buf.configureFrameRate(.nan)
        XCTAssertEqual(buf.maxFrameCount, 60)
        buf.configureFrameRate(.infinity)
        XCTAssertEqual(buf.maxFrameCount, 60)
    }
}
