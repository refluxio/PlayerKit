import XCTest
import AudioToolbox
@testable import PlayerKitNative

/// The 2026-10-10 seek-freeze deadlock: AudioUnitOutput.pause()/resume() ran
/// AudioQueuePause/AudioQueueStart synchronously on their CALLER's thread.
/// Those calls dispatch_sync into AudioToolbox's internal server context —
/// the same serial context the macOS CVDisplayLink tick runs on — so a
/// BeginPause stuck waiting for IO cycles (display path, underrun right after
/// a seek) blocked the demux thread's AudioQueueStart queued behind it,
/// freezing demux + display + the jitter heartbeats: the picture froze
/// permanently and every log went silent while the process burned ~50% CPU.
///
/// Contract after the fix: pause()/resume() flip the paused flag synchronously
/// but NEVER block the caller on the AudioQueue control call itself.
final class AudioUnitOutputControlNonBlockingTests: XCTestCase {

    override func tearDown() {
        AudioUnitOutput.pauseImpl = { AudioQueuePause($0) }
        AudioUnitOutput.startImpl = { AudioQueueStart($0, nil) }
        super.tearDown()
    }

    private func makeStartedOutput() -> AudioUnitOutput {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: 48000)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: 48000, channels: 2)
        return output
    }

    /// pause() must return while AudioQueuePause is still stuck in AudioToolbox.
    /// Against the synchronous implementation the caller blocks inside the seam
    /// until the semaphore is released — which only happens after the wait, so
    /// the "pause() returned" assertion times out (RED on the old code).
    func testPauseDoesNotBlockCallerWhenAudioQueuePauseIsStuck() throws {
        let output = makeStartedOutput()
        defer { output.stop() }
        guard output.hasQueueForTesting else {
            throw XCTSkip("no AudioQueue available in this environment")
        }

        let enteredControlCall = DispatchSemaphore(value: 0)
        let releaseControlCall = DispatchSemaphore(value: 0)
        AudioUnitOutput.pauseImpl = { _ in
            enteredControlCall.signal()
            releaseControlCall.wait()   // simulate a stuck AudioToolbox server context
            return noErr
        }

        let callerReturned = expectation(description: "pause() returned to caller")
        DispatchQueue.global().async {
            output.pause()
            callerReturned.fulfill()
        }
        wait(for: [callerReturned], timeout: 5)

        // The control call itself must still have been issued — just off-thread.
        XCTAssertEqual(enteredControlCall.wait(timeout: .now() + 5), .success,
            "pause() must still issue AudioQueuePause, only asynchronously")
        releaseControlCall.signal()
    }

    /// Same contract for resume(): the AudioQueueStart must happen off the
    /// caller's thread.
    func testResumeDoesNotBlockCallerWhenAudioQueueStartIsStuck() throws {
        let output = makeStartedOutput()
        defer { output.stop() }
        guard output.hasQueueForTesting else {
            throw XCTSkip("no AudioQueue available in this environment")
        }

        let enteredControlCall = DispatchSemaphore(value: 0)
        let releaseControlCall = DispatchSemaphore(value: 0)
        AudioUnitOutput.startImpl = { _ in
            enteredControlCall.signal()
            releaseControlCall.wait()   // simulate a stuck AudioToolbox server context
            return noErr
        }

        let callerReturned = expectation(description: "resume() returned to caller")
        DispatchQueue.global().async {
            output.resume()
            callerReturned.fulfill()
        }
        wait(for: [callerReturned], timeout: 5)

        XCTAssertEqual(enteredControlCall.wait(timeout: .now() + 5), .success,
            "resume() must still issue AudioQueueStart, only asynchronously")
        releaseControlCall.signal()
    }

    /// pause() → resume() must end UP resumed: the serial control queue keeps
    /// the Start after the Pause even though both are async, and the flush+
    /// enqueue-after-pause semantics (see PausedEnqueue tests) still play out.
    func testPauseThenResumeOrderIsPreservedAndAudioPlays() throws {
        let clock = AudioClock()
        clock.reset(to: 0, sampleRate: 48000)
        let output = AudioUnitOutput(clock: clock)
        output.start(sampleRate: 48000, channels: 2)
        defer { output.stop() }
        guard output.hasQueueForTesting else {
            throw XCTSkip("no AudioQueue available in this environment")
        }

        output.pause()
        let total = 40  // ~0.43s of silence
        for _ in 0..<total { output.enqueue(PCMFrame(data: Data(count: 512 * 2 * 4), pts: 0, sampleCount: 512)) }
        output.resume()

        let expected = Double(total * 512) / 48000.0
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if clock.audioTime >= expected - 0.02 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertGreaterThanOrEqual(clock.audioTime, expected - 0.02,
            "audio must keep playing after the async pause/resume pair (clock reached \(clock.audioTime)s of \(expected)s)")
    }
}
