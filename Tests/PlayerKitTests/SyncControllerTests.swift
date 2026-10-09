import XCTest
@testable import PlayerKitNative

final class SyncControllerTests: XCTestCase {

    func testFirstFrameAlwaysDisplayed() {
        let ctrl = SyncController()
        let (show, delay) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: 1000.0, serial: 0)
        XCTAssertTrue(show)
        XCTAssertEqual(delay, 0.0, "第一帧 delay 应为 0，让 advance() 不移动 frameTimer")
    }

    func testFrameNotDisplayedBeforeDelay() {
        let ctrl = SyncController()
        let now = 1000.0
        // 显示第一帧，delay=0，advance 后 frameTimer=now
        let (_, d0) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        ctrl.advance(delay: d0, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)

        // 立即查第二帧（now 未变），in-sync delay=0.04，now < now+0.04 → 不显示
        let (show2, _) = ctrl.check(nextPTS: 0.04, followingPTS: 0.08, audioTime: 0.0, now: now, serial: 0)
        XCTAssertFalse(show2)
    }

    func testFrameDisplayedAfterDelay() {
        let ctrl = SyncController()
        var now = 1000.0
        // 第一帧 delay=0，advance 后 frameTimer=1000.0
        let (_, d0) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        ctrl.advance(delay: d0, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)

        // 推进 >0.04s（标称帧时长），第二帧 in-sync delay≈0.04，now=1000.041 >= 1000.04 → 显示
        now += 0.041
        let (show2, _) = ctrl.check(nextPTS: 0.04, followingPTS: 0.08, audioTime: 0.0, now: now, serial: 0)
        XCTAssertTrue(show2)
    }

    func testLowPassSmoothingOnLag() {
        let ctrl = SyncController()
        let now = 1000.0
        let (_, d0) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        ctrl.advance(delay: d0, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)

        // 音频在 1.0s，视频 0.0s → diff=-1.0s（严重落后）
        // 低通：delay = 0.04 + 0.1×(-1.0) = -0.06 → clamp → 0（立即追帧）
        let (_, delay) = ctrl.check(nextPTS: 0.04, followingPTS: 0.08, audioTime: 1.0, now: now + 1.0, serial: 0)
        XCTAssertEqual(delay, 0.0, accuracy: 0.001)
    }

    /// 连续低通(无死区):同步区内的小幅 diff 也按 α·diff 连续校正,不再有
    /// "死区内不干预"。diff = 0.04 − 0.02 − 0.05(displayLatencyCompensation)
    /// = −0.03 → delay = 0.04 + 0.15·(−0.03) = 0.0355。
    func testLowPassCorrectionWithinSyncZone() {
        let ctrl = SyncController()
        let now = 1000.0
        let (_, d0) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        ctrl.advance(delay: d0, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)

        let (_, delay) = ctrl.check(nextPTS: 0.04, followingPTS: 0.08, audioTime: 0.02, now: now + 0.04, serial: 0)
        XCTAssertEqual(delay, 0.0355, accuracy: 0.001)
    }

    /// serial 变化(seek)→ frameTimer 重置为"该 tick 的 now":首个 serial-1 tick
    /// 重置基点不显示(与首帧立即显示路径不同,seek 后首帧走 reset()),再等一个
    /// delay 即可显示。对照 serial 未变的 controller:音频大幅落后把 delay 推高到
    /// ~53ms,同样等待不足以显示 —— 以此证明重置确实发生了(基点不同)。
    ///
    /// 数值:seeked 的 delay = 0.04 + 0.15·(30.0−30.0−0.05) = 0.0325;
    /// steady 的 delay = 0.04 + 0.15·(0.04−(−0.10)−0.05) = 0.0535。
    /// 断言时刻 1000.05:seeked 基点 1000.01 → 1000.05 ≥ 1000.0425 ✓ 显示;
    /// steady 基点 1000.0 → 1000.05 < 1000.0535 ✗ 不显示。
    func testSerialChangeResetsFrameTimer() {
        let now = 1000.0

        let seeked = SyncController()
        let (_, d0) = seeked.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        seeked.advance(delay: d0, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)
        // serial 0 → 1:frameTimer 从 1000.01 重新起算,该 tick 尚未到 delay
        let (showReset, _) = seeked.check(nextPTS: 30.0, followingPTS: 30.04, audioTime: 30.0, now: now + 0.01, serial: 1)
        XCTAssertFalse(showReset, "serial 变化 tick 只重置基点,不到 delay 不显示")
        // 40ms 后(> 0.0325):显示
        let (show, _) = seeked.check(nextPTS: 30.04, followingPTS: 30.08, audioTime: 30.0, now: now + 0.05, serial: 1)
        XCTAssertTrue(show, "serial 重置后 frameTimer 从新基点起算,一个 delay 内即可显示")

        let steady = SyncController()
        let (_, d1) = steady.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        steady.advance(delay: d1, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)
        // serial 未变,frameTimer 停在 1000:音频落后 100ms 把 delay 抬到 ~53ms,
        // 同样的 50ms 等待仍不够
        let (showSteady, _) = steady.check(nextPTS: 0.04, followingPTS: 0.08, audioTime: -0.10, now: now + 0.05, serial: 0)
        XCTAssertFalse(showSteady, "serial 未变时 frameTimer 基点未动,delay 未到不显示")
    }

    func testReset() {
        let ctrl = SyncController()
        let now = 1000.0
        let (_, d) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        ctrl.advance(delay: d, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)
        ctrl.reset()
        let (show, _) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        XCTAssertTrue(show, "reset 后应视为首帧，立即显示")
    }
}
