import XCTest
@testable import PlayerKitNative

/// Regression tests for the 2026-09-21 audio-loss bug.
///
/// `AudioUnitOutput.enqueue` used to silently DISCARD every decoded frame that
/// arrived while the queue was paused and already held 60 buffers (~0.64 s).
/// The pipeline pauses the audio queue whenever it (re)starts playback and the
/// video jitter buffer is still filling (~1.2 s on a 720p stream), while demux
/// and audio decode keep running — so ~0.55 s of audio was thrown away on every
/// start and another 0.6–0.7 s after every pause → resume. The audio clock and
/// the video carried on from before the dropped span, the audible content
/// jumped ahead: sound permanently ~0.6–1 s ahead of the picture.
///
/// Measured on the real movie (audio content position vs. the audio clock):
/// 52 dropped frames (0.555 s) ⇔ a +0.561 s audio-vs-clock step.
final class AudioUnitOutputPausedEnqueueTests: XCTestCase {

    private let sampleRate: Int32 = 48000
    private let samplesPerFrame = 512  // one DTS core frame — the size the app enqueues

    /// A silent stereo float32 frame (no sound is produced by these tests).
    private func silentFrame() -> PCMFrame {
        PCMFrame(data: Data(count: samplesPerFrame * 2 * 4), pts: 0, sampleCount: samplesPerFrame)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// Every frame handed to a paused queue must still be played after resume() as
    /// long as it stays within the paused cap (5 s): the audio clock (which counts
    /// consumed samples) has to reach the total duration enqueued, not stop at the
    /// 60 buffers (0.64 s of DTS) the old buffer-count cap allowed.
    func testFramesEnqueuedWhilePausedAndFullAreNotDiscarded() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        output.pause()
        let total = 100  // 1.07 s: more than the old 60-buffer cap, far below the 5 s cap
        for _ in 0..<total { output.enqueue(silentFrame()) }
        output.resume()

        let expected = Double(total * samplesPerFrame) / Double(sampleRate)  // 1.0667 s
        let reached = waitUntil(timeout: 4.0) { abs(clock.audioTime - expected) < 0.02 }
        XCTAssertTrue(reached,
            "expected ≈\(String(format: "%.3f", expected))s of audio to be played, "
            + "clock reached \(String(format: "%.3f", clock.audioTime))s "
            + "(\(Int(((expected - clock.audioTime) * Double(sampleRate)) / Double(samplesPerFrame))) frames lost)")
    }

    /// The protection the old cap existed for must survive: demux reads far
    /// faster than real time while the queue is paused (buffering), so the queue
    /// may not accumulate audio without bound. Beyond `maxPausedBufferSeconds`
    /// new frames are still discarded.
    func testPausedQueueStillHasABoundOnHowMuchAudioItAccumulates() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.maxPausedBufferSeconds = 0.5
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        output.pause()
        for _ in 0..<200 { output.enqueue(silentFrame()) }  // 2.13 s offered, 0.5 s allowed
        output.resume()

        Thread.sleep(forTimeInterval: 1.6)  // long enough to play everything that was kept
        let cap = 0.5
        XCTAssertGreaterThan(clock.audioTime, cap - 0.06, "the allowed 0.5 s must be played")
        XCTAssertLessThan(clock.audioTime, cap + 0.06,
                          "audio beyond maxPausedBufferSeconds must be dropped, not accumulated")
    }

    /// Frames held back while paused belong to the timeline that was in flight
    /// when flush() was called (seek / pause→resume rebuild): they must be
    /// discarded with it, never played after the next start().
    func testFlushDiscardsFramesHeldBackWhilePaused() {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: sampleRate)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: sampleRate, channels: 2)
        defer { output.stop() }

        output.pause()
        for _ in 0..<100 { output.enqueue(silentFrame()) }  // 40 of them are held back

        output.flush()                                       // old timeline ends here
        clock.reset(to: 0, sampleRate: sampleRate)
        output.start(sampleRate: sampleRate, channels: 2)    // new queue, new timeline
        let fresh = 10
        for _ in 0..<fresh { output.enqueue(silentFrame()) }

        let expected = Double(fresh * samplesPerFrame) / Double(sampleRate)  // 0.1067 s
        XCTAssertTrue(waitUntil(timeout: 3.0) { abs(clock.audioTime - expected) < 0.02 },
                      "new timeline must play exactly its own \(fresh) frames")
        // and nothing stale trickles in afterwards
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(clock.audioTime, expected, accuracy: 0.02,
                       "frames from the flushed timeline must not be played")
    }
}
