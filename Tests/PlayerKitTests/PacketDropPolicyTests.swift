import XCTest
@testable import PlayerKitNative

final class PacketDropPolicyTests: XCTestCase {
    func testKeyframeIsNeverDropped() {
        let policy = PacketDropPolicy()
        XCTAssertFalse(policy.shouldDrop(packetPTS: 0.0, audioTime: 10.0, isKeyframe: true))
    }
    func testNonKeyframeWithinThresholdNotDropped() {
        let policy = PacketDropPolicy()
        XCTAssertFalse(policy.shouldDrop(packetPTS: 0.9, audioTime: 1.0, isKeyframe: false))
    }
    func testNonKeyframeAtThresholdNotDropped() {
        let policy = PacketDropPolicy()
        // 恰好落后 0.2s（等于阈值）：不丢（严格小于才丢）
        XCTAssertFalse(policy.shouldDrop(packetPTS: 0.8, audioTime: 1.0, isKeyframe: false))
    }
    func testNonKeyframeBeyondThresholdDropped() {
        let policy = PacketDropPolicy()
        XCTAssertTrue(policy.shouldDrop(packetPTS: 0.79, audioTime: 1.0, isKeyframe: false))
    }
    func testAheadOfAudioNotDropped() {
        let policy = PacketDropPolicy()
        XCTAssertFalse(policy.shouldDrop(packetPTS: 5.0, audioTime: 1.0, isKeyframe: false))
    }
}
