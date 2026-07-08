import Foundation

/// ffplay-style frame_timer + low-pass A/V sync. Main-thread only — no locks needed.
final class SyncController {

    let alpha: Double = 0.1
    let maxDelay: Double = 0.5

    private var frameTimer: Double = 0
    private var frameTimerSerial: Int64 = -1
    private(set) var lastDisplayedPTS: Double = -1
    private var lastDuration: Double = 0.04

    /// Whether at least one frame has been displayed since creation or reset.
    /// Used by display loop to gate freeze/skip — first post-seek frame always shows.
    var hasDisplayedFrame: Bool { lastDisplayedPTS >= 0 }

    /// Call every CADisplayLink tick. Returns (shouldDisplay, computedDelay).
    /// Pass the returned delay to advance() when displaying.
    func check(nextPTS: Double,
               followingPTS: Double?,
               audioTime: Double,
               now: Double,
               serial: Int64) -> (Bool, Double) {

        if frameTimerSerial != serial {
            frameTimer = now
            frameTimerSerial = serial
        }

        // First frame after start/seek: display immediately, delay=0 so advance()
        // leaves frameTimer at 'now', and subsequent checks use nominal delay from there.
        if lastDisplayedPTS < 0 { return (true, 0) }

        let nominalDelay = nominalFrameDuration(nextPTS: nextPTS, followingPTS: followingPTS)
        let delay = computeDelay(nominalDelay: nominalDelay, nextPTS: nextPTS, audioTime: audioTime)
        return (now >= frameTimer + delay, delay)
    }

    /// Call after confirming a frame will be displayed.
    /// Uses the delay returned from check() — not the nominal duration — so A/V corrections
    /// actually affect when the next frame is shown.
    func advance(delay: Double, pts: Double, followingPTS: Double?, audioTime: Double, now: Double) {
        frameTimer += delay
        // AV_SYNC_FRAMEDUP_THRESHOLD: reset on system stall (e.g., app backgrounded)
        if now > frameTimer + 0.1 { frameTimer = now }
        lastDisplayedPTS = pts
        lastDuration = nominalFrameDuration(nextPTS: pts, followingPTS: followingPTS)
    }

    func reset() {
        frameTimer = 0
        frameTimerSerial = -1
        lastDisplayedPTS = -1
        lastDuration = 0.04
    }

    // MARK: - Private

    private func nominalFrameDuration(nextPTS: Double, followingPTS: Double?) -> Double {
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
        let diff = nextPTS - audioTime  // >0: video ahead; <0: video behind
        let delay = nominalDelay + alpha * diff
        return max(0, min(delay, maxDelay))
    }
}
