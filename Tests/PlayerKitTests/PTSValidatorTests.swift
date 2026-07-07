import XCTest
@testable import PlayerKitNative

final class PTSValidatorTests: XCTestCase {
    func testNormalPTSPassesThrough() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        XCTAssertEqual(v.validate(0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(v.validate(0.04), 0.04, accuracy: 0.001)
    }
    func testNaNPTSSwitchesToBlindClock() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        _ = v.validate(1.0)
        let result = v.validate(.nan)
        XCTAssertEqual(result, 1.04, accuracy: 0.001)
    }
    func testNegativePTSSwitchesToBlindClock() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        _ = v.validate(5.0)
        let result = v.validate(-1.0)
        XCTAssertEqual(result, 5.04, accuracy: 0.001)
    }
    func testLargeJumpSwitchesToBlindClock() {
        var v = PTSValidator(frameDuration: 1.0 / 25.0)
        _ = v.validate(1.0)
        let result = v.validate(7.0)  // 跳变 6s > jumpThreshold(5s)
        XCTAssertEqual(result, 1.04, accuracy: 0.001)
    }
    func testBlindClockContinuesIncrementing() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(1.0)
        _ = v.validate(.nan)  // predictPTS = 1.04
        let r2 = v.validate(.nan)  // predictPTS = 1.08
        XCTAssertEqual(r2, 1.08, accuracy: 0.001)
    }
    func testRecoveryFromBlindClock() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(1.0)
        _ = v.validate(.nan)  // 盲估 → predictPTS ≈ 1.04
        let result = v.validate(1.05)  // 与 predictPTS 偏差 < 1.0s → 切回
        XCTAssertEqual(result, 1.05, accuracy: 0.001)
    }
    func testResetClearsState() {
        var v = PTSValidator(frameDuration: 0.04)
        _ = v.validate(100.0)
        v.reset()
        let result = v.validate(0.0)  // reset 后首帧不触发跳变检测
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }
}
