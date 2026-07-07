import XCTest
@testable import PlayerKitNative

final class AudioClockTests: XCTestCase {

    func testInitialAudioTimeIsZero() {
        let clock = AudioClock()
        XCTAssertEqual(clock.audioTime, 0.0)
    }

    func testAdvanceByOneSecond() {
        let clock = AudioClock()
        // 44100Hz, 2ch, float32: 1秒 = 44100 × 2 × 4 = 352800 bytes
        clock.advance(byteCount: 352800, channels: 2)
        XCTAssertEqual(clock.audioTime, 1.0, accuracy: 0.001)
    }

    func testPrimeDebtClampsToZero() {
        let clock = AudioClock()
        // 3个 primer buffer，每个 4096 bytes，2ch → 欠账 1536 样本
        clock.primeDebt(bufferCount: 3, bytesPerBuffer: 4096, channels: 2)
        XCTAssertEqual(clock.audioTime, 0.0, "primer 债务期间 audioTime 应被夹到 0")
    }

    func testPrimeDebtPaidOff() {
        let clock = AudioClock()
        clock.primeDebt(bufferCount: 3, bytesPerBuffer: 4096, channels: 2)
        // 消费 3 × 4096 bytes 的 primer 数据（偿清债务）
        clock.advance(byteCount: 3 * 4096, channels: 2)
        XCTAssertEqual(clock.audioTime, 0.0, accuracy: 0.001, "债务还清后 audioTime 应为 0")
    }

    func testResetToPosition() {
        let clock = AudioClock()
        clock.advance(byteCount: 352800, channels: 2) // 推进到 1.0s
        clock.reset(to: 10.5, sampleRate: 44100)
        XCTAssertEqual(clock.audioTime, 10.5, accuracy: 0.001)
    }

    func testResetWithDifferentSampleRate() {
        let clock = AudioClock()
        clock.reset(to: 5.0, sampleRate: 48000)
        XCTAssertEqual(clock.audioTime, 5.0, accuracy: 0.001)
        // 48000Hz, 2ch: 1秒 = 48000 × 2 × 4 = 384000 bytes
        clock.advance(byteCount: 384000, channels: 2)
        XCTAssertEqual(clock.audioTime, 6.0, accuracy: 0.001)
    }

    func testThreadSafety() {
        let clock = AudioClock()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            clock.advance(byteCount: 352, channels: 2)
            _ = clock.audioTime
        }
        XCTAssertGreaterThan(clock.audioTime, 0)
    }
}
