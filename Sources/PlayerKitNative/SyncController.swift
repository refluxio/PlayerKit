import Foundation

/// ffplay-style frame_timer + low-pass A/V sync. Main-thread only — no locks needed.
final class SyncController {

    let alpha: Double = 0.1
    let syncThresholdMin: Double = 0.04
    let syncThresholdMax: Double = 0.10
    let maxDelay: Double = 0.15

    private var frameTimer: Double = 0
    private var frameTimerSerial: Int64 = -1
    private var lastDisplayedPTS: Double = -1
    private var lastDuration: Double = 0.04

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
        let delay = computeDelay(nominalDelay: nominalDelay, audioTime: audioTime)
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

    private func computeDelay(nominalDelay: Double, audioTime: Double) -> Double {
        let diff = lastDisplayedPTS - audioTime  // >0: video ahead; <0: video behind
        let syncThreshold = max(syncThresholdMin, min(syncThresholdMax, nominalDelay))
        var delay = nominalDelay
        if abs(diff) >= syncThreshold {
            // Low-pass: correct α×diff per frame rather than all at once
            delay = nominalDelay + alpha * diff
        }
        return max(0, min(delay, maxDelay))
    }
}
