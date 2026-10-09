import Foundation

/// ffplay-style frame_timer + low-pass A/V sync.
///
/// Threading (P2 display-off-main): check()/advance() run on the display-link
/// thread — video presentation no longer waits for the main thread — while
/// reset() arrives from main-thread lifecycle paths (seek/resume/stop/open).
/// All mutable state is therefore guarded by `lock`.
final class SyncController {

    private let lock = NSLock()

    let alpha: Double = 0.15
    let maxDelay: Double = 0.5

    /// Display pipeline latency compensation. ASBDLRenderer.enqueue() is
    /// async — the frame appears on screen ~1-2 vsync intervals after enqueue.
    /// Without compensation, sync thinks video is on-time but the user sees
    /// audio/subtitles ahead of video. This offset makes sync treat video as
    /// slightly behind audio, so it speeds up video to compensate.
    /// 50ms ≈ 2 frames at 24fps — covers ASBDL's HDR tone mapping + vsync wait.
    let displayLatencyCompensation: Double = 0.05

    private var frameTimer: Double = 0
    private var frameTimerSerial: Int64 = -1
    private var lastDisplayedPTS: Double = -1
    private var lastDuration: Double = 0.04

    /// Whether at least one frame has been displayed since creation or reset.
    /// Used by display loop to gate freeze/skip — first post-seek frame always shows.
    var hasDisplayedFrame: Bool {
        lock.withLock { lastDisplayedPTS >= 0 }
    }

    /// Call every display tick. Returns (shouldDisplay, computedDelay).
    /// Pass the returned delay to advance() when displaying.
    func check(nextPTS: Double,
               followingPTS: Double?,
               audioTime: Double,
               now: Double,
               serial: Int64) -> (Bool, Double) {

        lock.lock(); defer { lock.unlock() }

        if frameTimerSerial != serial {
            frameTimer = now
            frameTimerSerial = serial
        }

        // First frame after start/seek: display immediately, delay=0 so advance()
        // leaves frameTimer at 'now', and subsequent checks use nominal delay from there.
        if lastDisplayedPTS < 0 { return (true, 0) }

        let nominalDelay = nominalFrameDurationLocked(nextPTS: nextPTS, followingPTS: followingPTS)
        let delay = computeDelay(nominalDelay: nominalDelay, nextPTS: nextPTS, audioTime: audioTime)
        return (now >= frameTimer + delay, delay)
    }

    /// Call after confirming a frame will be displayed.
    /// Uses the delay returned from check() — not the nominal duration — so A/V corrections
    /// actually affect when the next frame is shown.
    func advance(delay: Double, pts: Double, followingPTS: Double?, audioTime: Double, now: Double) {
        lock.lock(); defer { lock.unlock() }
        frameTimer += delay
        // AV_SYNC_FRAMEDUP_THRESHOLD: reset on system stall (e.g., app backgrounded)
        if now > frameTimer + 0.1 { frameTimer = now }
        lastDisplayedPTS = pts
        lastDuration = nominalFrameDurationLocked(nextPTS: pts, followingPTS: followingPTS)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        frameTimer = 0
        frameTimerSerial = -1
        lastDisplayedPTS = -1
        lastDuration = 0.04
    }

    // MARK: - Private (call only under lock)

    private func nominalFrameDurationLocked(nextPTS: Double, followingPTS: Double?) -> Double {
        if let f = followingPTS, f > nextPTS { return f - nextPTS }
        return lastDuration > 0 ? lastDuration : 0.04
    }

    private func computeDelay(nominalDelay: Double, nextPTS: Double, audioTime: Double) -> Double {
        // Continuous low-pass correction: delay = nominal + α·diff, no hard
        // threshold. The previous `if abs(diff) >= syncThreshold` gate made the
        // correction kick in/out across consecutive frames as diff hovered near
        // the threshold, causing delay to oscillate between nominalDelay and
        // nominalDelay + α·diff → frame pacing jitter / 来回拉扯.
        // With α=0.1 and typical diff in ±50ms, correction is ±5ms — well below
        // one-frame duration (~33ms) and imperceptible, but still pulls video
        // toward audio continuously.
        //
        // displayLatencyCompensation: ASBDLRenderer.enqueue() is async, so the
        // frame actually appears on screen 1-2 vsyncs after we call enqueue.
        // Without this, sync thinks video is on-time but the user perceives
        // audio/subtitles ahead of video. Subtracting the compensation from
        // diff makes sync think video is slightly behind, speeding it up.
        let diff = nextPTS - audioTime - displayLatencyCompensation
        let delay = nominalDelay + alpha * diff
        return max(0, min(delay, maxDelay))
    }
}
