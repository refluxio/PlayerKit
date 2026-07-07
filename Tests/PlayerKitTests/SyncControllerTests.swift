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

    func testNoInterventionInSyncZone() {
        let ctrl = SyncController()
        let now = 1000.0
        let (_, d0) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        ctrl.advance(delay: d0, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)

        // diff = 0.0 - 0.02 = -0.02s < syncThreshold(0.04)：死区内不干预
        let (_, delay) = ctrl.check(nextPTS: 0.04, followingPTS: 0.08, audioTime: 0.02, now: now + 0.04, serial: 0)
        XCTAssertEqual(delay, 0.04, accuracy: 0.001)
    }

    func testSerialChangeResetsFrameTimer() {
        let ctrl = SyncController()
        let now = 1000.0
        let (_, d0) = ctrl.check(nextPTS: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now, serial: 0)
        ctrl.advance(delay: d0, pts: 0.0, followingPTS: 0.04, audioTime: 0.0, now: now)

        // serial 变化（seek）→ frameTimer 重置为 now → 首帧立即显示
        let (show, _) = ctrl.check(nextPTS: 30.0, followingPTS: 30.04, audioTime: 30.0, now: now, serial: 1)
        XCTAssertTrue(show)
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
