import XCTest
@testable import PlayerKitNative

/// Regression test for the 2026-09-21 "sound runs ahead of the picture after
/// pause → resume" bug.
///
/// `NativeBackend.resume()` rebuilds the pipeline (audio queue re-created,
/// jitter buffer flushed) but then resumed the audio queue immediately, while
/// the video needs ~1 s to refill. Audio played that second on its own, then
/// the clock was calibrated to the first video frame — leaving the sound ahead
/// of the picture by the refill time (measured on the real movie: +0.97 s; on
/// the 30 s fixture ≈ +0.9 s). The first start of playback already avoids this
/// by keeping the queue paused until the jitter buffer flips to `.playing`
/// (see `_finishOpen`); resume must follow the same protocol.
final class ResumeAVSyncTests: XCTestCase {

    private var savedLog = false
    private var savedMute = false

    override func setUp() {
        savedLog = AudioUnitOutput.tracksPlayedContent; savedMute = AudioUnitOutput.mutedForTesting
        AudioUnitOutput.tracksPlayedContent = true   // enables the played-content tracking used by the seam
        AudioUnitOutput.mutedForTesting = true  // silent: the fixture must not make noise on the dev machine
    }
    override func tearDown() {
        AudioUnitOutput.tracksPlayedContent = savedLog; AudioUnitOutput.mutedForTesting = savedMute
    }

    private func fixtureURL() -> URL {
        Bundle.module.url(forResource: "speed_dts48_51", withExtension: "mkv",
                          subdirectory: "Fixtures")!
    }

    /// Median of the audio-vs-clock gap sampled over `seconds`.
    private func medianGap(_ backend: NativeBackend, over seconds: Double) async throws -> Double {
        var gaps: [Double] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await Task.sleep(nanoseconds: 100_000_000)
            let g: Double = await MainActor.run { backend.audioContentGapForTesting() }
            if g.isFinite { gaps.append(g) }
        }
        XCTAssertFalse(gaps.isEmpty, "no audio-vs-clock samples were produced")
        return gaps.sorted()[gaps.count / 2]
    }

    func testAudioStaysInSyncWithPictureAfterPauseAndResume() async throws {
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run { backend.play(url: fixtureURL(), headers: [:], seekTo: nil) }
        try await Task.sleep(nanoseconds: 4_000_000_000)

        let before = try await medianGap(backend, over: 1.5)
        XCTAssertEqual(before, 0, accuracy: 0.1, "sanity: in sync before the pause")

        await MainActor.run { backend.pause() }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        await MainActor.run { backend.resume() }
        try await Task.sleep(nanoseconds: 3_500_000_000)   // let the refill finish

        let after = try await medianGap(backend, over: 2.0)
        XCTAssertEqual(after, 0, accuracy: 0.1,
            "after pause→resume the audio content is \(String(format: "%+.3f", after))s "
            + "from the clock the picture follows (positive = sound ahead of picture)")
    }
}

/// Regression test for the 2026-09-21 "audio from the OLD position after a seek" bug.
///
/// A cast at a position starts as play(url) and, ~30 ms later, a separate seek
/// (the app does exactly this). Audio packets read from the old position before
/// the physical seek lands are decoded asynchronously and end up in the audio
/// queue that `_seek` had already restarted, so the old position's audio was
/// played first while the picture was already at the target (measured on the
/// real movie: −0.86 s with the old 60-buffer cap, −2.60 s with a 5 s cap).
final class TwoStepStartAVSyncTests: XCTestCase {

    private var savedLog = false
    private var savedMute = false
    override func setUp() {
        continueAfterFailure = false
        savedLog = AudioUnitOutput.tracksPlayedContent; savedMute = AudioUnitOutput.mutedForTesting
        AudioUnitOutput.tracksPlayedContent = true
        AudioUnitOutput.mutedForTesting = true
    }
    override func tearDown() {
        AudioUnitOutput.tracksPlayedContent = savedLog; AudioUnitOutput.mutedForTesting = savedMute
    }

    /// play(url), then a separate seek 30 ms later — what the app does for a cast at a
    /// position — then the median audio-content-vs-clock gap over 2 s.
    private func gapAfterPlayThenSeek(to target: Double) async throws -> Double? {
        let url = Bundle.module.url(forResource: "speed_dts48_51", withExtension: "mkv",
                                    subdirectory: "Fixtures")!
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }
        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await MainActor.run { backend.seek(to: .seconds(target)) }
        try await Task.sleep(nanoseconds: 4_500_000_000)

        var gaps: [Double] = []
        let end = Date().addingTimeInterval(2.0)
        while Date() < end {
            try await Task.sleep(nanoseconds: 100_000_000)
            let g: Double = await MainActor.run { backend.audioContentGapForTesting() }
            if g.isFinite { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    /// The fixture has a keyframe every 2.002 s (10.010, 12.012, ...).
    /// Target just after a keyframe: isolates AUDIO from the old position that was
    /// decoded before the physical seek landed but reached the restarted queue.
    func testNoAudioFromTheOldPositionAfterPlayThenSeek() async throws {
        guard let g = try await gapAfterPlayThenSeek(to: 12.02) else {
            return XCTFail("no audio was ever played after play→seek")
        }
        XCTAssertEqual(g, 0, accuracy: 0.1,
            "audio content is \(String(format: "%+.3f", g))s from the clock the picture follows")
    }

    /// Target in the MIDDLE of a GOP (keyframe at 10.010, target 12.0): the seek lands
    /// on the keyframe. Video frames from the OLD position are still coming out of the
    /// decoder until the physical seek lands and they consumed the one-shot clock
    /// calibration (|0.5 − 12| is fine here, but on a real movie |0.5 − 240| > 15 s made
    /// it skip calibration AND clear the flag): the clock stayed at the target while the
    /// audio started at the keyframe → audio behind the picture by (target − keyframe)
    /// (measured −2.005 s on the real movie, −1.984 s on this fixture).
    func testAudioAndPictureAgreeAfterPlayThenSeekIntoTheMiddleOfAGOP() async throws {
        guard let g = try await gapAfterPlayThenSeek(to: 12.0) else {
            return XCTFail("no audio was ever played after play→seek")
        }
        XCTAssertEqual(g, 0, accuracy: 0.1,
            "audio content is \(String(format: "%+.3f", g))s from the clock the picture follows "
            + "(negative = sound from an EARLIER position than the picture)")
    }
}
